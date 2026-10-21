{ BCJ2-style filter for x86 (own format, not 7z-compatible).

  Input is split into four streams:
    0: main bytes (converted branch operands removed)
    1: CALL/JMP targets
    2: Jcc targets
    3: one bit per branch marker (1 = converted, 0 = literal operand remains in main)
  The three byte streams are LZMA-compressed separately; the bit stream is stored raw.
  Stream 3 can be compressed later if it pays off.

  Header (little endian):
    'PCB2', origSize:U32, candidates:U32,
    mainRaw, callRaw, jumpRaw, svcRaw: U32,
    mainComp, callComp, jumpComp: U32
  Raw fallback: 'PCB0', origSize:U32, original bytes. }
unit parc_bcj2;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream, parc_outstream;

type
  TBcj2EncStage = class(TOutStage)
  private
    FData: TBytes;
    FLen: SizeInt;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage);
  end;

  TBcj2DecStage = class(TInStage)
  private
    FOut: TBytes;
    FPos, FLen: SizeInt;
    FLoaded: Boolean;
    procedure Load;
  public
    constructor Create(ASource: TInStage);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

implementation

uses
  Classes, parc_bytes, parc_lzma, parc_lzmaenc;

const
  MAGIC_RAW = $30424350;   // 'PCB0'
  MAGIC_BCJ = $32424350;   // 'PCB2'
  PREFIX_CALL = 1;
  PREFIX_JCC = 2;

procedure PutU32(var B: TBytes; Pos: SizeInt; V: LongWord); inline;
begin
  B[Pos] := V and $FF;
  B[Pos+1] := (V shr 8) and $FF;
  B[Pos+2] := (V shr 16) and $FF;
  B[Pos+3] := V shr 24;
end;

function GetU32(const B: TBytes; Pos: SizeInt): LongWord; inline;
begin
  Result := LongWord(B[Pos]) or (LongWord(B[Pos+1]) shl 8) or
            (LongWord(B[Pos+2]) shl 16) or (LongWord(B[Pos+3]) shl 24);
end;

function LoadI32(p: PByte): LongInt; inline;
begin
  Result := LongInt(LongWord(p[0]) or (LongWord(p[1]) shl 8) or
                    (LongWord(p[2]) shl 16) or (LongWord(p[3]) shl 24));
end;

procedure StoreU32(p: PByte; V: LongWord); inline;
begin
  p[0] := V and $FF; p[1] := (V shr 8) and $FF;
  p[2] := (V shr 16) and $FF; p[3] := V shr 24;
end;

{ Devuelve 1 para E8/E9, 2 para 0F 80..8F, 0 si no es marcador o no entra. }
function MarkerKind(Data: PByte; Size: SizeInt; Pos: SizeInt): Integer; inline;
begin
  Result := 0;
  if Pos + 5 > Size then Exit;
  if Data[Pos] in [$E8, $E9] then Exit(1);
  if (Pos + 6 <= Size) and (Data[Pos] = $0F) and (Data[Pos+1] and $F0 = $80) then Exit(2);
end;

function LzmaParamsFor(DictSize: QWord; lc, lp, pb: Integer): TLzmaEncParams; inline;
begin
  Result := DefaultLzmaEncParams;
  Result.DictSize := DictSize;
  Result.Algorithm := 1;          // normal/optimal
  Result.NumFastBytes := 273;
  Result.MatchFinder := mfBT4;
  Result.MatchFinderCycles := 0;
  Result.NumThreads := 1;
  Result.lc := lc; Result.lp := lp; Result.pb := pb;
end;

function CompressStream(const Src: TBytes; DictSize: QWord; lc, lp, pb: Integer): TBytes;
begin
  if Length(Src) = 0 then Exit(nil);
  Result := LzmaEncodeMem(PByte(Src), Length(Src), LzmaParamsFor(DictSize, lc, lp, pb), False);
end;

function DecompressStream(const Src: TBytes; DstSize: SizeInt; lc, lp, pb: Integer): TBytes;
var
  Written: SizeInt;
begin
  Result := nil;
  if DstSize = 0 then Exit;
  SetLength(Result, DstSize);
  if (Length(Src) = 0) or
     (LzmaDecodeRaw(PByte(Src), Length(Src), PByte(Result), DstSize, lc, lp, pb, Written) <> lzOk) or
     (Written <> DstSize) then
    Corrupt('bcj2: bad LZMA stream');
end;

function Bcj2Compress(const Src: TBytes): TBytes;
var
  Size, i, Prefix, Cand, BitPos, nMain, nCall, nJump, nSvc: SizeInt;
  Main, CallS, JumpS, Svc: TBytes;
  MainC, CallC, JumpC: TBytes;
  Target: Int64;
  Raw: Boolean;
begin
  Size := Length(Src);
  if Size = 0 then
  begin
    SetLength(Result, 4);
    PutU32(Result, 0, MAGIC_RAW);
    Exit;
  end;
  // Holgura: cada marcador puede dejar 4 bytes fuera del main y 3 streams chicos.
  SetLength(Main, Size);
  SetLength(CallS, Size);
  SetLength(JumpS, Size);
  SetLength(Svc, (Size + 7) div 8 + 1);
  nMain := 0; nCall := 0; nJump := 0; nSvc := 0; Cand := 0;
  i := 0;
  while i < Size do
  begin
    Prefix := MarkerKind(PByte(Src), Size, i);
    if Prefix <> 0 then
    begin
      if (Cand and 7) = 0 then Svc[nSvc] := 0;
      BitPos := Cand and 7;
      Inc(Cand);
      if Prefix = 1 then
      begin
        Target := Int64(i) + 5 + LoadI32(PByte(Src) + i + 1);
        if (Target >= Low(LongInt)) and (Target <= High(LongInt)) then
        begin
          Main[nMain] := Src[i]; Inc(nMain);
          StoreU32(@CallS[nCall], LongWord(LongInt(Target))); Inc(nCall, 4);
          Svc[nSvc] := Svc[nSvc] or (1 shl BitPos);
          if BitPos = 7 then Inc(nSvc);
          Inc(i, 5);
          Continue;
        end;
      end
      else
      begin
        Target := Int64(i) + 6 + LoadI32(PByte(Src) + i + 2);
        if (Target >= Low(LongInt)) and (Target <= High(LongInt)) then
        begin
          Main[nMain] := Src[i]; Inc(nMain);
          Main[nMain] := Src[i+1]; Inc(nMain);
          StoreU32(@JumpS[nJump], LongWord(LongInt(Target))); Inc(nJump, 4);
          Svc[nSvc] := Svc[nSvc] or (1 shl BitPos);
          if BitPos = 7 then Inc(nSvc);
          Inc(i, 6);
          Continue;
        end;
      end;
      if BitPos = 7 then Inc(nSvc);
      // No convertido: el marcador y su operando quedan en el main. Se copian juntos para
      // que el decodificador, al leer el bit 0, avance exactamente lo mismo.
      Move(Src[i], Main[nMain], Prefix + 4);
      Inc(nMain, Prefix + 4); Inc(i, Prefix + 4);
      Continue;
    end;
    Main[nMain] := Src[i]; Inc(nMain); Inc(i);
  end;
  if (Cand > 0) and ((Cand and 7) <> 0) then Inc(nSvc);
  SetLength(Main, nMain);
  SetLength(CallS, nCall);
  SetLength(JumpS, nJump);
  SetLength(Svc, nSvc);

  MainC := CompressStream(Main, 24 shl 20, 3, 0, 2);
  CallC := CompressStream(CallS, 512 shl 10, 0, 2, 2);
  JumpC := CompressStream(JumpS, 512 shl 10, 0, 2, 2);

  Raw := (16 + 24 + Length(MainC) + Length(CallC) + Length(JumpC) + Length(Svc)) >= Size;
  if Raw then
  begin
    SetLength(Result, 8 + Size);
    PutU32(Result, 0, MAGIC_RAW);
    PutU32(Result, 4, LongWord(Size));
    if Size > 0 then Move(Src[0], Result[8], Size);
    Exit;
  end;

  SetLength(Result, 48 + Length(MainC) + Length(CallC) + Length(JumpC) + Length(Svc));
  PutU32(Result, 0, MAGIC_BCJ);
  PutU32(Result, 4, LongWord(Size));
  PutU32(Result, 8, LongWord(Cand));
  PutU32(Result, 12, LongWord(Length(Main)));
  PutU32(Result, 16, LongWord(Length(CallS)));
  PutU32(Result, 20, LongWord(Length(JumpS)));
  PutU32(Result, 24, LongWord(Length(Svc)));
  PutU32(Result, 28, LongWord(Length(MainC)));
  PutU32(Result, 32, LongWord(Length(CallC)));
  PutU32(Result, 36, LongWord(Length(JumpC)));
  PutU32(Result, 40, 0);
  PutU32(Result, 44, 0);
  nMain := 48;
  if Length(MainC) > 0 then begin Move(MainC[0], Result[nMain], Length(MainC)); Inc(nMain, Length(MainC)); end;
  if Length(CallC) > 0 then begin Move(CallC[0], Result[nMain], Length(CallC)); Inc(nMain, Length(CallC)); end;
  if Length(JumpC) > 0 then begin Move(JumpC[0], Result[nMain], Length(JumpC)); Inc(nMain, Length(JumpC)); end;
  if Length(Svc) > 0 then Move(Svc[0], Result[nMain], Length(Svc));
end;

function Bcj2Decompress(const Src: TBytes): TBytes;
var
  Magic, Orig, Cand, MainRaw, CallRaw, JumpRaw, SvcRaw, MainC, CallC, JumpC: LongWord;
  Main, CallS, JumpS, Svc: TBytes;
  OutPos, MainPos, CallPos, JumpPos, BitPos, i, Prefix, Kind, Rel: SizeInt;
  Target: Int64;
  Mask: Byte;
begin
  if Length(Src) < 4 then Corrupt('bcj2: truncated header');
  Magic := GetU32(Src, 0);
  if Magic = MAGIC_RAW then
  begin
    if Length(Src) < 8 then Corrupt('bcj2: truncated raw header');
    Orig := GetU32(Src, 4);
    if Length(Src) < 8 + SizeInt(Orig) then Corrupt('bcj2: truncated raw data');
    SetLength(Result, Orig);
    if Orig > 0 then Move(Src[8], Result[0], Orig);
    Exit;
  end;
  if (Magic <> MAGIC_BCJ) or (Length(Src) < 48) then Corrupt('bcj2: bad header');
  Orig := GetU32(Src, 4);
  Cand := GetU32(Src, 8);
  MainRaw := GetU32(Src, 12);
  CallRaw := GetU32(Src, 16);
  JumpRaw := GetU32(Src, 20);
  SvcRaw := GetU32(Src, 24);
  MainC := GetU32(Src, 28);
  CallC := GetU32(Src, 32);
  JumpC := GetU32(Src, 36);
  if Int64(48) + MainC + CallC + JumpC + SvcRaw > Length(Src) then Corrupt('bcj2: truncated streams');
  i := 48;
  SetLength(Main, MainC); if MainC > 0 then Move(Src[i], Main[0], MainC);
  Main := DecompressStream(Main, MainRaw, 3, 0, 2); Inc(i, MainC);
  SetLength(CallS, CallC); if CallC > 0 then Move(Src[i], CallS[0], CallC);
  CallS := DecompressStream(CallS, CallRaw, 0, 2, 2); Inc(i, CallC);
  SetLength(JumpS, JumpC); if JumpC > 0 then Move(Src[i], JumpS[0], JumpC);
  JumpS := DecompressStream(JumpS, JumpRaw, 0, 2, 2); Inc(i, JumpC);
  SetLength(Svc, SvcRaw); if SvcRaw > 0 then Move(Src[i], Svc[0], SvcRaw);

  SetLength(Result, Orig);
  OutPos := 0; MainPos := 0; CallPos := 0; JumpPos := 0; BitPos := 0;
  while OutPos < SizeInt(Orig) do
  begin
    if MainPos >= Length(Main) then Corrupt('bcj2: main stream truncated');
    Kind := MarkerKind(PByte(Main), Length(Main), MainPos);
    // En el main faltan los operandos de los marcadores convertidos; para decidir si el
    // marcador entra en el bloque hay que mirar la posición de salida, no sólo el main.
    if (Main[MainPos] in [$E8, $E9]) and (OutPos + 5 <= SizeInt(Orig)) then Kind := PREFIX_CALL
    else if (Main[MainPos] = $0F) and (MainPos + 1 < Length(Main)) and
            (Main[MainPos+1] and $F0 = $80) and (OutPos + 6 <= SizeInt(Orig)) then Kind := PREFIX_JCC
    else Kind := 0;
    if Kind <> 0 then
    begin
      if BitPos >= Length(Svc) * 8 then Corrupt('bcj2: service stream truncated');
      Mask := Svc[BitPos shr 3];
      if (Mask and (1 shl (BitPos and 7))) <> 0 then
      begin
        Result[OutPos] := Main[MainPos]; Inc(MainPos);
        if Kind = PREFIX_CALL then
        begin
          if CallPos + 4 > Length(CallS) then Corrupt('bcj2: call stream truncated');
          Target := Int64(LoadI32(@CallS[CallPos])); Inc(CallPos, 4);
          Rel := SizeInt(Target - (Int64(OutPos) + 5));
          if (Rel < Low(LongInt)) or (Rel > High(LongInt)) then Corrupt('bcj2: call target');
          StoreU32(@Result[OutPos+1], LongWord(Rel));
          Inc(OutPos, 5);
        end
        else
        begin
          Result[OutPos+1] := Main[MainPos]; Inc(MainPos);
          if JumpPos + 4 > Length(JumpS) then Corrupt('bcj2: jump stream truncated');
          Target := Int64(LoadI32(@JumpS[JumpPos])); Inc(JumpPos, 4);
          Rel := SizeInt(Target - (Int64(OutPos) + 6));
          if (Rel < Low(LongInt)) or (Rel > High(LongInt)) then Corrupt('bcj2: jump target');
          StoreU32(@Result[OutPos+2], LongWord(Rel));
          Inc(OutPos, 6);
        end;
      end
      else
      begin
        // No convertido: los operandos están en el main.
        Prefix := Kind;
        if MainPos + Prefix + 4 > Length(Main) then Corrupt('bcj2: main literal truncated');
        Move(Main[MainPos], Result[OutPos], Prefix + 4);
        Inc(MainPos, Prefix + 4); Inc(OutPos, Prefix + 4);
      end;
      Inc(BitPos);
    end
    else
    begin
      Result[OutPos] := Main[MainPos];
      Inc(MainPos); Inc(OutPos);
    end;
  end;
  if (MainPos <> Length(Main)) or (CallPos <> Length(CallS)) or (JumpPos <> Length(JumpS)) then
    Corrupt('bcj2: trailing stream data');
end;

{ Stages }

constructor TBcj2EncStage.Create(ATarget: TOutStage);
begin
  inherited Create(ATarget);
  FLen := 0;
end;

procedure TBcj2EncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  Cap: SizeInt;
begin
  if Count <= 0 then Exit;
  if FLen + Count > Length(FData) then
  begin
    Cap := Length(FData);
    if Cap = 0 then Cap := 64 * 1024;
    while Cap < FLen + Count do Cap := Cap * 2;
    SetLength(FData, Cap);
  end;
  Move(Buf^, FData[FLen], Count);
  Inc(FLen, Count);
end;

procedure TBcj2EncStage.DoFinish;
var
  Enc: TBytes;
begin
  SetLength(FData, FLen);
  Enc := Bcj2Compress(FData);
  if Length(Enc) > 0 then Emit(@Enc[0], Length(Enc));
  FData := nil;
  inherited DoFinish;
end;

constructor TBcj2DecStage.Create(ASource: TInStage);
begin
  inherited Create(ASource);
  FLoaded := False;
  FPos := 0; FLen := 0;
end;

procedure TBcj2DecStage.Load;
var
  Buf: TBytes;
  n, Cap: SizeInt;
begin
  if FLoaded then Exit;
  SetLength(Buf, 64 * 1024);
  Cap := 0;
  repeat
    n := Source.Read(@Buf[0], Length(Buf));
    if n <= 0 then Break;
    if Cap + n > Length(FOut) then
    begin
      while Cap + n > Length(FOut) do
        if Length(FOut) = 0 then SetLength(FOut, 64 * 1024) else SetLength(FOut, Length(FOut) * 2);
    end;
    Move(Buf[0], FOut[Cap], n);
    Inc(Cap, n);
  until False;
  SetLength(FOut, Cap);
  FOut := Bcj2Decompress(FOut);
  FLen := Length(FOut);
  FPos := 0;
  FLoaded := True;
end;

function TBcj2DecStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  Load;
  Result := FLen - FPos;
  if Result > Count then Result := Count;
  if Result > 0 then
  begin
    Move(FOut[FPos], Buf^, Result);
    Inc(FPos, Result);
  end;
end;

end.
