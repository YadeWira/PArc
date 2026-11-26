{ PArc's recovery record (`-rr`, `rr`, `r`): layout, sizing, building and repair.
  Format: docs/formato/FORMATO-PARC.md §5 (record version 1, 2026-11). Own design around the
  Reed-Solomon erasure code of parc_rs.

  The protected area (the archive from its head to the end locator) is cut into N sectors of
  `sector size` bytes (the last one shorter). Sector i belongs to stripe i mod S, at position
  i div S; every stripe has at most 255 - m data sectors and m parity sectors (RS over GF(2^8),
  parc_rs), and parity j of stripe s is parity sector j*S + s. A stripe is rebuilt when at most
  m of its sectors (data or parity) are damaged; a contiguous damage of up to S*m sectors puts
  at most m in each stripe.

  Damaged sectors are found with a short check per sector (the low 16 bits of its CRC-32; 32
  bits in a record without parity), and every repaired stripe is verified against a CRC-32 of
  the whole stripe: a damaged sector whose check happens to match (2^-16) is then found by
  trying each sector of the stripe as the missing one. The record is located from the end of
  the file by its descriptor, kept at both ends of the record; the stripe CRC table is also
  kept twice. Repair rewrites everything it can prove damaged, the record included, so a
  repaired archive is byte-identical to the original.

  Layout (all little-endian):
    descriptor (48)  · stripe table (S x U32 + U32 CRC) · checks ((N + S*m) x W)
    · parity sectors (S*m x sector size) · stripe table again · descriptor again }
unit parc_recovery;

{$mode objfpc}{$H+}
{$modeswitch nestedprocvars}

interface

uses
  Classes, SysUtils, parc_bytes, parc_archive;

type
  TInt64Arr = array of Int64;

  TRecoveryInfo = record
    Version: string;     // 'parc-rr1'
    ProtLen: Int64;      // protected bytes
    SectorSize: Integer;
    Parity: Integer;     // m (0: checks only, no repair)
    Stripes: Int64;      // S
    RecSectors: Int64;   // S * m
    RecLen: Int64;       // bytes of the whole record
  end;

  TRecoveryResult = record
    Info: TRecoveryInfo;
    BadSectors: TInt64Arr;           // damaged sectors of the protected area
    BadRecord: Int64;                // damaged bytes/structures of the record itself (count of parts)
    Unrecoverable: TInt64Arr;        // protected sectors (or stripes) that could not be rebuilt
    Repaired: TInt64Arr;
  end;

{ Sizes the record for ProtLen protected bytes. False if Spec is not valid. }
function RecoveryPlan(ProtLen: Int64; const Spec: string; out SectorSize, Parity: Integer;
  out Stripes, RecLen: Int64): Boolean;

{ True if Spec is a valid -rr specification. }
function RecoverySpecValid(const Spec: string): Boolean;

{ Appends the record to S, protecting S[Base, Base + ProtLen) (S.Position must be at its end). }
procedure WriteRecoveryRecord(S: TStream; Base, ProtLen: Int64; const Spec: string);

{ Checks the archive with its record and, if something is damaged and repairable, writes
  DestName (fixed.<name>) with it repaired; the original is never touched. DestName is '' if
  nothing was written. False if the archive has no recovery record. }
function RecoveryRepair(const ArcName: string; out Res: TRecoveryResult;
                        out DestName: string): Boolean;

implementation

uses
  Math, parc_crc, parc_volume, parc_rs, parc_progress;

const
  RR_VERSION = 'parc-rr1';
  MIN_SECTOR = 512;
  MAX_SECTOR = 64 shl 20;
  MAX_AUTO_SECTORS = 1 shl 25;   // automatic sizing: at most 32 Mi sectors (64 MB of checks)
  IO_CHUNK = 4 shl 20;

type
  TBoolArr = array of Boolean;

{ --- -rr specification ----------------------------------------------------------------- }

{ A decimal number (digits, optional '.' and digits) at S[p..]. }
function ParseDecimal(const S: string; var p: Integer; out V: Double): Boolean;
var
  q: Integer;
begin
  q := p;
  while (p <= Length(S)) and (S[p] in ['0'..'9']) do Inc(p);
  if (p <= Length(S)) and (S[p] = '.') then
  begin
    Inc(p);
    while (p <= Length(S)) and (S[p] in ['0'..'9']) do Inc(p);
  end;
  Result := (p > q) and (S[q] <> '.') and TryStrToFloat(Copy(S, q, p - q), V, DefaultFormatSettings);
  if not Result then
  begin
    // the decimal separator of the locale must not matter
    Result := (p > q) and (S[q] <> '.') and TryStrToFloat(StringReplace(Copy(S, q, p - q), '.', DefaultFormatSettings.DecimalSeparator, []), V);
  end;
end;

{ A byte size: number + b | k | m | g (k/m/g optionally followed by b); no unit = Default. }
function ParseByteSize(const S: string; out V: Int64; DefaultUnit: Int64): Boolean;
var
  p: Integer;
  D: Double;
  U: string;
  Mul: Int64;
begin
  Result := False;
  V := 0;
  p := 1;
  if not ParseDecimal(S, p, D) then Exit;
  U := LowerCase(Copy(S, p, MaxInt));
  case U of
    '': Mul := DefaultUnit;
    'b': Mul := 1;
    'k', 'kb': Mul := 1024;
    'm', 'mb': Mul := 1024 * 1024;
    'g', 'gb': Mul := 1024 * 1024 * 1024;
  else
    Exit;
  end;
  if D * Mul > 4.0e18 then Exit;
  V := Round(D * Mul);
  Result := True;
end;

type
  TRrKind = (rkPercent, rkBytes, rkCount);
  TRrSpec = record
    Kind: TRrKind;
    Percent: Double;     // rkPercent
    Bytes: Int64;        // rkBytes: budget of the whole record
    Count: Int64;        // rkCount: parity sectors wanted (0: checks only)
    Sector: Int64;       // 0 = automatic
  end;

{ Grammar (docs/USO.md "-rr"): <amount>[;<sector>] or <count>*<sector>, where <amount> is
  N% (of the protected size), N or Ns (N sectors of the sector size, 512 by default), or
  N b/k/m/g (bytes); <sector> is a byte size (no unit: bytes). }
function ParseSpec(const Spec: string; out R: TRrSpec): Boolean;
var
  A, Sec: string;
  p: Integer;
  D: Double;
begin
  Result := False;
  R := Default(TRrSpec);
  A := Trim(Spec);
  if A = '' then Exit;
  p := Pos('*', A);
  if p > 0 then
  begin
    if not ParseByteSize(Copy(A, p + 1, MaxInt), R.Sector, 1) then Exit;
    A := Copy(A, 1, p - 1);
    if (A = '') or not TryStrToInt64(A, R.Count) or (R.Count < 0) then Exit;
    R.Kind := rkCount;
    Exit((R.Sector >= MIN_SECTOR) and (R.Sector <= MAX_SECTOR));
  end;
  p := Pos(';', A);
  if p > 0 then
  begin
    Sec := Copy(A, p + 1, MaxInt);
    A := Copy(A, 1, p - 1);
    if not ParseByteSize(Sec, R.Sector, 1) or (R.Sector < MIN_SECTOR) or (R.Sector > MAX_SECTOR) then Exit;
  end;
  if A = '' then Exit;
  if A[Length(A)] = '%' then
  begin
    p := 1;
    if not ParseDecimal(A, p, D) or (p <> Length(A)) or (D <= 0) or (D > 100) then Exit;
    R.Kind := rkPercent;
    R.Percent := D;
    Exit(True);
  end;
  if A[Length(A)] in ['s', 'S'] then Delete(A, Length(A), 1);
  if (A <> '') and (A[Length(A)] in ['0'..'9']) then
  begin
    // N sectors: of the given size, or of 512 bytes
    if not TryStrToInt64(A, R.Count) or (R.Count <= 0) then Exit;
    if R.Sector = 0 then R.Sector := MIN_SECTOR;
    R.Kind := rkBytes;
    R.Bytes := R.Count * R.Sector;
    Exit(True);
  end;
  if not ParseByteSize(A, R.Bytes, 1) or (R.Bytes <= 0) then Exit;
  R.Kind := rkBytes;
  Result := True;
end;

function RecoverySpecValid(const Spec: string): Boolean;
var
  R: TRrSpec;
begin
  Result := ParseSpec(Spec, R);
end;

{ Bytes of the whole record. }
function RecordLen(N: Int64; SS, m: Integer; S: Int64; W: Integer): Int64;
begin
  Result := 2 * REC_DESC_SIZE + 2 * (4 * S + 4) + Int64(W) * (N + S * m) + S * m * Int64(SS);
end;

function CheckWidthFor(m: Integer): Integer;
begin
  if m > 0 then Result := 2 else Result := 4;
end;

{ The largest m (1..254) whose record fits in Budget; 0 if not even m = 1 fits. }
function BestParity(N: Int64; SS: Integer; Budget: Int64; out S: Int64): Integer;
var
  m: Integer;
  Sm: Int64;
begin
  Result := 0;
  S := 0;
  for m := 1 to 254 do
  begin
    Sm := RsStripeCount(N, m);
    if RecordLen(N, SS, m, Sm, 2) > Budget then Break;
    Result := m;
    S := Sm;
  end;
end;

function RecoveryPlan(ProtLen: Int64; const Spec: string; out SectorSize, Parity: Integer;
  out Stripes, RecLen: Int64): Boolean;
var
  R: TRrSpec;
  Budget, N, S, Best, Value: Int64;
  SS, m, BestSS, BestM: Integer;
  BestS: Int64;
begin
  Result := False;
  SectorSize := 0; Parity := 0; Stripes := 0; RecLen := 0;
  if (ProtLen <= 0) or not ParseSpec(Spec, R) then Exit;
  if R.Kind = rkCount then
  begin
    SectorSize := R.Sector;
    N := (ProtLen + SectorSize - 1) div SectorSize;
    if R.Count > 0 then
    begin
      // the smallest m with S*m >= Count
      m := 1;
      while (m < 254) and (RsStripeCount(N, m) * m < R.Count) do Inc(m);
      Parity := m;
      Stripes := RsStripeCount(N, m);
    end;
    RecLen := RecordLen(N, SectorSize, Parity, Stripes, CheckWidthFor(Parity));
    Exit(True);
  end;
  if R.Kind = rkPercent then Budget := Round(ProtLen * R.Percent / 100.0)
  else Budget := R.Bytes;
  // Sector size: the smallest (from 512 bytes, powers of two) whose checks take at most 1/8 of
  // the budget, and with at most 32 Mi sectors; given with ";<size>": that one. Then as many
  // parity sectors per stripe as fit (at least one).
  if R.Sector > 0 then SS := R.Sector
  else
  begin
    SS := MIN_SECTOR;
    while (SS < MAX_SECTOR) and (((ProtLen + SS - 1) div SS > MAX_AUTO_SECTORS) or
                                 (2 * ((ProtLen + SS - 1) div SS) > Budget div 8)) do
      SS := SS * 2;
  end;
  N := (ProtLen + SS - 1) div SS;
  BestSS := SS;
  BestM := BestParity(N, SS, Budget, BestS);
  if BestM = 0 then
  begin
    // the budget does not reach one parity sector per stripe: one anyway
    BestM := 1;
    BestS := RsStripeCount(N, 1);
  end;
  SectorSize := BestSS;
  Parity := BestM;
  Stripes := BestS;
  RecLen := RecordLen((ProtLen + SectorSize - 1) div SectorSize, SectorSize, Parity, Stripes, 2);
  Result := True;
end;

{ --- record parts ------------------------------------------------------------------------ }

type
  TRecData = record
    D: TRecDesc;
    N: Int64;               // data sectors
    P: Int64;               // parity sectors (S*m)
    StripeCrc: array of LongWord;
    Checks: TBytes;         // (N + P) x W
    Parity: TBytes;         // P x sector size
  end;

function StripeTable(const R: TRecData): TBytes;
var
  i: Int64;
begin
  SetLength(Result, 4 * R.D.Stripes + 4);
  i := 0;
  while i < R.D.Stripes do
  begin
    PutU32(@Result[4 * i], R.StripeCrc[i]);
    Inc(i);
  end;
  PutU32(@Result[4 * R.D.Stripes], CalcCRC(PByte(Result), 4 * R.D.Stripes));
end;

type
  TEmitProc = procedure(P: PByte; Len: Int64) is nested;

{ The record's bytes, in order, in pieces. }
procedure EmitRecord(const R: TRecData; Emit: TEmitProc);
var
  Desc: array[0..REC_DESC_SIZE - 1] of Byte;
  T: TBytes;
begin
  EncodeRecDesc(@Desc[0], R.D);
  T := StripeTable(R);
  Emit(@Desc[0], REC_DESC_SIZE);
  Emit(PByte(T), Length(T));
  Emit(PByte(R.Checks), Length(R.Checks));
  Emit(PByte(R.Parity), Length(R.Parity));
  Emit(PByte(T), Length(T));
  Emit(@Desc[0], REC_DESC_SIZE);
end;

procedure PutCheck(var R: TRecData; Idx: Int64; Crc: LongWord); inline;
begin
  if R.D.CheckWidth = 2 then
  begin
    R.Checks[2 * Idx] := Byte(Crc);
    R.Checks[2 * Idx + 1] := Byte(Crc shr 8);
  end
  else
    PutU32(@R.Checks[4 * Idx], Crc);
end;

function CheckMatches(const R: TRecData; Idx: Int64; Crc: LongWord): Boolean; inline;
begin
  if R.D.CheckWidth = 2 then
    Result := (R.Checks[2 * Idx] = Byte(Crc)) and (R.Checks[2 * Idx + 1] = Byte(Crc shr 8))
  else
    Result := GetU32(@R.Checks[4 * Idx]) = Crc;
end;

{ --- building ---------------------------------------------------------------------------- }

procedure WriteRecoveryRecord(S: TStream; Base, ProtLen: Int64; const Spec: string);
var
  R: TRecData;
  SS, m, j, Got, n, x: Integer;
  Stripes, RecLen, k, Sector, si, pi, i: Int64;
  ii: SizeInt;
  jj: Integer;
  Buf, Pad: TBytes;
  Done: Int64;
  Written: Int64;

  procedure Put(P: PByte; Len: Int64);
  begin
    if Len > 0 then S.WriteBuffer(P^, Len);
    Inc(Written, Len);
  end;

begin
  if not RecoveryPlan(ProtLen, Spec, SS, m, Stripes, RecLen) then
    raise Exception.CreateFmt('invalid -rr specification: "%s"', [Spec]);
  R := Default(TRecData);
  R.D.ProtLen := ProtLen;
  R.D.RecLen := RecLen;
  R.D.Stripes := Stripes;
  R.D.SectorSize := SS;
  R.D.Parity := m;
  R.D.CheckWidth := CheckWidthFor(m);
  R.N := (ProtLen + SS - 1) div SS;
  R.P := Stripes * m;
  SetLength(R.StripeCrc, Stripes);
  for ii := 0 to Stripes - 1 do R.StripeCrc[ii] := CRC_INIT;
  SetLength(R.Checks, (R.N + R.P) * R.D.CheckWidth);
  SetLength(R.Parity, R.P * SS);
  if Length(R.Parity) > 0 then FillChar(R.Parity[0], Length(R.Parity), 0);
  // One pass over the protected area, in chunks of whole sectors
  n := (IO_CHUNK div SS) * SS;
  if n < SS then n := SS;
  SetLength(Buf, n);
  SetLength(Pad, SS);
  S.Position := Base;
  Sector := 0;
  Done := 0;
  while Done < ProtLen do
  begin
    Got := n;
    if Done + Got > ProtLen then Got := ProtLen - Done;
    S.ReadBuffer(Buf[0], Got);
    x := 0;
    while x < Got do
    begin
      j := SS;
      if x + j > Got then j := Got - x;
      PutCheck(R, Sector, CalcCRC(@Buf[x], j));
      if m > 0 then
      begin
        si := Sector mod Stripes;
        pi := Sector div Stripes;
        R.StripeCrc[si] := UpdateCRC(R.StripeCrc[si], @Buf[x], j);
        if j < SS then
        begin
          // the last sector, zero-padded
          FillChar(Pad[0], SS, 0);
          Move(Buf[x], Pad[0], j);
          for jj := 0 to m - 1 do
            RsMulAdd(RsCoef(jj, pi), @Pad[0], @R.Parity[(jj * Stripes + si) * SS], SS);
        end
        else
          for jj := 0 to m - 1 do
            RsMulAdd(RsCoef(jj, pi), @Buf[x], @R.Parity[(jj * Stripes + si) * SS], SS);
      end;
      Inc(x, j);
      Inc(Sector);
    end;
    Inc(Done, Got);
    CheckCancel;
  end;
  for ii := 0 to Stripes - 1 do R.StripeCrc[ii] := R.StripeCrc[ii] xor CRC_INIT;
  for ii := 0 to R.P - 1 do PutCheck(R, R.N + ii, CalcCRC(@R.Parity[ii * SS], SS));
  S.Position := Base + ProtLen;
  Written := 0;
  EmitRecord(R, @Put);
  if Written <> RecLen then raise Exception.Create('recovery record: unexpected size');
end;

{ --- repair ------------------------------------------------------------------------------ }

{ Finds the record: the descriptor at the end of the file, or (damaged) the other copy by a
  backwards scan. RecPos: where the record starts. }
function FindRecord(F: TStream; out D: TRecDesc; out RecPos: Int64; out DescOk: Boolean): Boolean;
var
  Size, Lo, Hi, P: Int64;
  Buf: TBytes;
  n, i: SizeInt;
begin
  Result := False;
  DescOk := False;
  RecPos := 0;
  Size := F.Size;
  if Size < REC_DESC_SIZE then Exit;
  SetLength(Buf, 1 shl 20);
  F.Position := Size - REC_DESC_SIZE;
  F.ReadBuffer(Buf[0], REC_DESC_SIZE);
  if DecodeRecDesc(@Buf[0], D) and (D.RecLen <= Size) and (D.ProtLen <= Size - D.RecLen) then
  begin
    RecPos := Size - D.RecLen;
    DescOk := True;
    Exit(True);
  end;
  // The first descriptor, by its magic ("PArr" at offset 44)
  Hi := Size;
  while Hi > 0 do
  begin
    Lo := Hi - (Length(Buf) - REC_DESC_SIZE);
    if Lo < 0 then Lo := 0;
    n := Hi - Lo + REC_DESC_SIZE;
    if Lo + n > Size then n := Size - Lo;
    F.Position := Lo;
    F.ReadBuffer(Buf[0], n);
    for i := n - REC_DESC_SIZE downto 0 do
      if (Buf[i + 44] = $50) and (Buf[i + 45] = $41) and (Buf[i + 46] = $72) and (Buf[i + 47] = $72) and
         DecodeRecDesc(@Buf[i], D) then
      begin
        P := Lo + i;
        if (P + D.RecLen <= Size) and (D.ProtLen <= P) then
        begin
          RecPos := P;
          Exit(True);
        end;
      end;
    CheckCancel;
    Hi := Lo;
  end;
end;

procedure ReadFull(F: TStream; Pos: Int64; P: PByte; Len: Int64);
begin
  F.Position := Pos;
  if Len > 0 then F.ReadBuffer(P^, Len);
end;

function TableOk(const T: TBytes; S: Int64): Boolean;
begin
  Result := (Length(T) = 4 * S + 4) and (GetU32(@T[4 * S]) = CalcCRC(PByte(T), 4 * S));
end;


function RecoveryRepair(const ArcName: string; out Res: TRecoveryResult;
                        out DestName: string): Boolean;
var
  F: TStream;
  Outp: TFileStream;
  R: TRecData;
  RecPos, Start, N, P, S, k, i, st, idx, Base, TabLen, CmpPos: Int64;
  ii: SizeInt;
  SS, m, W, kk, q, j, Got, x, nchunk, Try_, Len: Integer;
  DescOk, TabOk, Fixed, Differs: Boolean;
  TA, TB, Saved, Buf, Mem, Cmp: TBytes;
  Bad, BadPar: TBoolArr;
  PerStripe: array of Integer;
  Computed: array of LongWord;
  Ptrs: array of PByte;
  Present, Erased: array of Boolean;
  VolBase: string;

  procedure Note(var A: TInt64Arr; V: Int64);
  begin
    SetLength(A, Length(A) + 1);
    A[High(A)] := V;
  end;

  function SectorLen(idx: Int64): Integer;
  begin
    Result := SS;
    if (idx + 1) * SS > R.D.ProtLen then Result := R.D.ProtLen - idx * SS;
  end;

  function StripeCrcOf(st: Int64; kk: Integer): LongWord;
  var
    q: Integer;
  begin
    Result := CRC_INIT;
    for q := 0 to kk - 1 do Result := UpdateCRC(Result, Ptrs[q], SectorLen(Int64(q) * S + st));
    Result := Result xor CRC_INIT;
  end;

  { fixed.<name>: a copy of the original, made the first time something has to be written. }
  procedure EnsureOut;
  begin
    if Outp <> nil then Exit;
    if not IsVolumeSet(ArcName, VolBase) then VolBase := ArcName;
    DestName := ExtractFilePath(VolBase) + 'fixed.' + ExtractFileName(VolBase);
    if FileExists(DestName) then DeleteFile(DestName);
    Outp := TFileStream.Create(DestName, fmCreate);
    F.Position := 0;
    Outp.CopyFrom(F, F.Size);
  end;

  procedure Compare(Ptr: PByte; L: Int64);
  var
    c: Int64;
  begin
    while (L > 0) and not Differs do
    begin
      c := L;
      if c > Length(Cmp) then c := Length(Cmp);
      ReadFull(F, CmpPos, @Cmp[0], c);
      if CompareByte(Cmp[0], Ptr^, c) <> 0 then Differs := True;
      Inc(CmpPos, c);
      Inc(Ptr, c);
      Dec(L, c);
    end;
  end;

  procedure WriteOut(Ptr: PByte; L: Int64);
  begin
    if L > 0 then Outp.WriteBuffer(Ptr^, L);
  end;

begin
  Result := False;
  DestName := '';
  Res := Default(TRecoveryResult);
  Outp := nil;
  F := OpenArchiveStream(ArcName);
  try
    try
      if not FindRecord(F, R.D, RecPos, DescOk) then Exit;
      Result := True;
      SS := R.D.SectorSize;
      m := R.D.Parity;
      S := R.D.Stripes;
      W := R.D.CheckWidth;
      N := (R.D.ProtLen + SS - 1) div SS;
      P := S * m;
      R.N := N;
      R.P := P;
      Res.Info.Version := RR_VERSION;
      Res.Info.ProtLen := R.D.ProtLen;
      Res.Info.SectorSize := SS;
      Res.Info.Parity := m;
      Res.Info.Stripes := S;
      Res.Info.RecSectors := P;
      Res.Info.RecLen := R.D.RecLen;
      if ((m > 0) and (S <> RsStripeCount(N, m))) or ((m = 0) and (S <> 0)) or
         (W <> CheckWidthFor(m)) or (R.D.RecLen <> RecordLen(N, SS, m, S, W)) or
         (Int64(RS_MAX_SECTORS) * SS > High(SizeInt) div 2) then
        Corrupt('recovery record with invalid parameters');
      Start := RecPos - R.D.ProtLen;
      // Stripe tables (two copies), checks, parity
      TabLen := 4 * S + 4;
      SetLength(TA, TabLen);
      SetLength(TB, TabLen);
      ReadFull(F, RecPos + REC_DESC_SIZE, PByte(TA), TabLen);
      ReadFull(F, RecPos + R.D.RecLen - REC_DESC_SIZE - TabLen, PByte(TB), TabLen);
      TabOk := True;
      if TableOk(TA, S) then Saved := TA
      else if TableOk(TB, S) then Saved := TB
      else TabOk := False;
      SetLength(R.StripeCrc, S);
      if TabOk then
        for ii := 0 to S - 1 do R.StripeCrc[ii] := GetU32(@Saved[4 * ii]);
      SetLength(R.Checks, (N + P) * W);
      ReadFull(F, RecPos + REC_DESC_SIZE + TabLen, PByte(R.Checks), Length(R.Checks));
      SetLength(R.Parity, P * SS);
      ReadFull(F, RecPos + REC_DESC_SIZE + TabLen + Length(R.Checks), PByte(R.Parity), Length(R.Parity));

      // Scan: damaged sectors, and the CRC of every stripe as it is
      SetLength(Bad, N);
      SetLength(BadPar, P);
      SetLength(PerStripe, S);
      SetLength(Computed, S);
      for ii := 0 to S - 1 do Computed[ii] := CRC_INIT;
      nchunk := (IO_CHUNK div SS) * SS;
      if nchunk < SS then nchunk := SS;
      SetLength(Buf, nchunk);
      k := 0;
      Base := 0;
      while Base < R.D.ProtLen do
      begin
        Got := nchunk;
        if Base + Got > R.D.ProtLen then Got := R.D.ProtLen - Base;
        ReadFull(F, Start + Base, @Buf[0], Got);
        x := 0;
        while x < Got do
        begin
          j := SS;
          if x + j > Got then j := Got - x;
          Bad[k] := not CheckMatches(R, k, CalcCRC(@Buf[x], j));
          if S > 0 then
          begin
            st := k mod S;
            Computed[st] := UpdateCRC(Computed[st], @Buf[x], j);
            if Bad[k] then Inc(PerStripe[st]);
          end;
          if Bad[k] then Note(Res.BadSectors, k);
          Inc(x, j);
          Inc(k);
        end;
        Inc(Base, Got);
        CheckCancel;
      end;
      Buf := nil;
      for ii := 0 to S - 1 do Computed[ii] := Computed[ii] xor CRC_INIT;
      if not TabOk then
      begin
        Inc(Res.BadRecord);
        for ii := 0 to S - 1 do R.StripeCrc[ii] := Computed[ii];
      end;
      for ii := 0 to P - 1 do
      begin
        BadPar[ii] := not CheckMatches(R, N + ii, CalcCRC(@R.Parity[ii * SS], SS));
        if BadPar[ii] then
        begin
          Inc(PerStripe[ii mod S]);
          Inc(Res.BadRecord);
        end;
      end;

      if m = 0 then
      begin
        // checks only: report, do not repair
        Res.Unrecoverable := Copy(Res.BadSectors, 0, Length(Res.BadSectors));
        Exit;
      end;

      // Rebuild every stripe with damage, or whose CRC does not match (undetected damage)
      SetLength(Mem, Int64(RS_MAX_SECTORS) * SS);
      SetLength(Saved, Int64(RS_MAX_SECTORS) * SS);
      SetLength(Ptrs, RS_MAX_SECTORS);
      SetLength(Present, RS_MAX_SECTORS);
      SetLength(Erased, RS_MAX_SECTORS);
      st := 0;
      while st < S do
      begin
        if (PerStripe[st] = 0) and (Computed[st] = R.StripeCrc[st]) then
        begin
          Inc(st);
          Continue;
        end;
        kk := RsStripeLen(N, S, st);
        if PerStripe[st] > m then
        begin
          for q := 0 to kk - 1 do
            if Bad[Int64(q) * S + st] then Note(Res.Unrecoverable, Int64(q) * S + st);
          Inc(st);
          Continue;
        end;
        // the stripe as it is (damaged sectors too), then rebuild it
        for q := 0 to kk + m - 1 do Ptrs[q] := @Mem[Int64(q) * SS];
        for q := 0 to kk - 1 do
        begin
          idx := Int64(q) * S + st;
          FillChar(Ptrs[q]^, SS, 0);
          ReadFull(F, Start + idx * SS, Ptrs[q], SectorLen(idx));
          Erased[q] := Bad[idx];
        end;
        for j := 0 to m - 1 do
        begin
          Move(R.Parity[(Int64(j) * S + st) * SS], Ptrs[kk + j]^, SS);
          Erased[kk + j] := BadPar[Int64(j) * S + st];
        end;
        Len := (kk + m) * SS;
        Move(Mem[0], Saved[0], Len);
        Fixed := False;
        // Try_ = -1: the detected erasures; then each other sector in turn as an undetected one
        // (while there is a spare parity)
        Try_ := -1;
        while Try_ < kk + m do
        begin
          if (Try_ >= 0) and (Erased[Try_] or (PerStripe[st] + 1 > m)) then
          begin
            Inc(Try_);
            Continue;
          end;
          Move(Saved[0], Mem[0], Len);
          for q := 0 to kk + m - 1 do Present[q] := not Erased[q] and (q <> Try_);
          if RsRecover(kk, m, Ptrs[0..kk + m - 1], Present[0..kk + m - 1], SS) and
             (StripeCrcOf(st, kk) = R.StripeCrc[st]) then
          begin
            Fixed := True;
            Break;
          end;
          if not TabOk then Break;   // nothing to verify against: the detected erasures only
          Inc(Try_);
        end;
        if not Fixed and not TabOk then
          // without a stripe table the rebuilt stripe cannot be checked: trust the erasures
          Fixed := RsRecover(kk, m, Ptrs[0..kk + m - 1], Present[0..kk + m - 1], SS);
        if not Fixed then
        begin
          if PerStripe[st] = 0 then Note(Res.Unrecoverable, st)   // CRC mismatch, sector unknown
          else
            for q := 0 to kk - 1 do
              if Bad[Int64(q) * S + st] then Note(Res.Unrecoverable, Int64(q) * S + st);
          Inc(st);
          Continue;
        end;
        if not TabOk then R.StripeCrc[st] := StripeCrcOf(st, kk);
        // data sectors that changed go to the output; their checks are rewritten
        for q := 0 to kk - 1 do
        begin
          idx := Int64(q) * S + st;
          if (not Bad[idx]) and (CompareByte(Ptrs[q]^, Saved[Int64(q) * SS], SS) = 0) then Continue;
          if not Bad[idx] then
          begin
            Bad[idx] := True;
            Note(Res.BadSectors, idx);
          end;
          PutCheck(R, idx, CalcCRC(Ptrs[q], SectorLen(idx)));
          if CompareByte(Ptrs[q]^, Saved[Int64(q) * SS], SectorLen(idx)) <> 0 then
          begin
            EnsureOut;
            Outp.Position := Start + idx * SS;
            Outp.WriteBuffer(Ptrs[q]^, SectorLen(idx));
          end;
          Note(Res.Repaired, idx);
        end;
        // parity: rebuilt ones replace the damaged ones
        for j := 0 to m - 1 do
        begin
          idx := Int64(j) * S + st;
          if CompareByte(Ptrs[kk + j]^, R.Parity[idx * SS], SS) <> 0 then
          begin
            Move(Ptrs[kk + j]^, R.Parity[idx * SS], SS);
            if not BadPar[idx] then Inc(Res.BadRecord);
          end;
          PutCheck(R, N + idx, CalcCRC(Ptrs[kk + j], SS));
        end;
        CheckCancel;
        Inc(st);
      end;
      Mem := nil;
      Saved := nil;

      // The record itself: rewritten if it is not what it should be (descriptors, tables,
      // checks of damaged or falsely flagged sectors, rebuilt parity)
      SetLength(Cmp, 1 shl 20);
      CmpPos := RecPos;
      Differs := F.Size <> RecPos + R.D.RecLen;
      if not Differs then EmitRecord(R, @Compare);
      if Differs then
      begin
        if Res.BadRecord = 0 then Inc(Res.BadRecord);
        EnsureOut;
        Outp.Position := RecPos;
        EmitRecord(R, @WriteOut);
        Outp.Size := RecPos + R.D.RecLen;
      end;
    except
      if Outp <> nil then
      begin
        FreeAndNil(Outp);
        DeleteFile(DestName);
        DestName := '';
      end;
      raise;
    end;
  finally
    Outp.Free;
    F.Free;
  end;
end;

end.
