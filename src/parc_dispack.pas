{ dispack: PArc's own filter for x86 and x86-64 machine code (MIT; it replaces FreeArc's DisPack
  0.70 and is not derived from it). Method names `dispack`, `dispack070` and the preset `exe2`.

  Executable code compresses poorly as it is: every instruction mixes opcodes, register fields,
  displacements, immediates and relative branch targets, each with its own statistics, and a call
  to the same function has a different relative offset from every place it is called. The filter
  decodes the instructions (own length decoder written from the Intel and AMD opcode maps) and
  moves the fields whose statistics differ most to their own streams:

    OP     prefixes, opcode bytes (with the VEX/EVEX payload), ModRM, SIB, 8-bit displacements,
           8-bit immediates, 8-bit relative branches, and escapes
    D32    32-bit (and 16-bit) base-relative displacements
    ADDR   absolute addresses: [disp32] without a base register, moffs, and RIP-relative
           displacements converted to absolute (x86-64)
    I16 / I32   16-bit and 32-bit immediates (I32 also takes the 64-bit ones)
    CALL   E8 targets as absolute addresses      JMP    E9 / 0F 8x targets as absolute
    RAW    the bytes that are not code
  The short fields stay with the opcode on purpose: an LZ or CM back end then sees whole
  instruction shapes (opcode + ModRM + disp8 ...) repeat, and the 32-bit fields, which are
  mostly unpredictable from their neighbours, no longer break those repeats. Absolute addresses
  are written most significant byte first (their high bytes repeat). Measured alternatives that
  lost with LZMA and plz: one stream per field, a move-to-front table for call targets, jump-table
  detection, little-endian addresses. Every decision of the walker is made from bytes the
  decoder has already rebuilt, so it is exact for any input; garbage parsed as code is only less
  compressible. Escape: an instruction starting with D6 (SALC, undefined in 64-bit mode) is
  written D6 00; D6 n (n = 1..63) is followed by n raw bytes (an instruction cut by the end of a
  region).

  Which bytes are code: the encoder looks for PE (i386 / AMD64, not .NET) and ELF (i386 /
  x86-64) headers in the data and takes their code sections (PE) or executable segments (ELF)
  with their bitness and virtual addresses; spans outside any executable found this way are
  classified by a density test of near calls (E8 with a small offset) in 4 KB windows, as 64-bit
  code when REX.W prefixes are common.

  Stream (version 1; docs/formato/FORMATO-PARC.md §6.6):
    U8 version (= 1), then blocks until the end of the stream:
      VInt Len (bytes of the block, 1..block size), VInt NReg (code regions),
      NReg x ( VInt Gap (raw bytes before the region), VInt RegLen, U8 Mode (0 = 32-bit,
               1 = 64-bit), U32 Va (virtual address of its first byte) ),
      XF_NSTREAMS x VInt StreamLen,
      zero padding to a multiple of 4 bytes from the version byte, then the streams in order,
      each followed by zero padding to a multiple of 4.
    VInt is LEB128 (7 bits per byte, low group first). U32 little endian.
  The block's bytes are: Gap raw bytes (from RAW), the region (decoded from the streams), ...,
  and the rest of the block from RAW. }
unit parc_dispack;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$pointermath on}
{$inline on}

interface

uses
  SysUtils, parc_stream, parc_outstream;

const
  XF_VERSION = 1;
  DISPACK_BLOCK = 8 * 1024 * 1024;        // default block
  XF_MAX_BLOCK = 1 shl 30;

  XS_OP = 0; XS_D32 = 1; XS_ADDR = 2; XS_I16 = 3; XS_I32 = 4; XS_CALL = 5; XS_JMP = 6;
  XS_RAW = 7;
  XF_NSTREAMS = 8;

type
  TXfRegion = record
    Start, Len: Int64;        // absolute in the stream (encoder) or in the block
    Mode: Byte;               // 32 or 64
    Va, ImageBase: LongWord;
  end;
  TXfRegionArray = array of TXfRegion;

  TXfCtx = record
    P, E: array[0..XF_NSTREAMS - 1] of PByte;   // current position, end (decoder)
    Buf: array[0..XF_NSTREAMS - 1] of array of Byte;   // encoder buffers
  end;

  { Encoder stage. Params = the method split on ':' (Params[0] = 'dispack'/'dispack070'). }
  TDisPackEncStage = class(TOutStage)
  private
    FBlock: SizeInt;
    FBuf: array of Byte;
    FLen: SizeInt;
    FBase: Int64;                 // stream position of FBuf[0]
    FRegs: TXfRegionArray;        // code ranges found in headers (absolute)
    FNRegs: Integer;
    FSpans: TXfRegionArray;       // whole executables found (no heuristic inside)
    FNSpans: Integer;
    FHeaderDone: Boolean;
    FOutPos: QWord;
    FCtx: TXfCtx;
    procedure AddReg(const R: TXfRegion);
    procedure AddSpan(AStart, ALen: Int64);
    procedure ScanHeaders(N: SizeInt);
    procedure ProcessBlock(N: SizeInt);
    procedure DumpBlock(const Rs: TXfRegionArray; NR: Integer; const Len: array of SizeInt);
    procedure Out(Buf: PByte; Count: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; ABlockSize: SizeInt);
  end;

  TDisPackStage = class(TInStage)
  private
    FMaxBlock: SizeInt;
    FIn: array of Byte;
    FOut: array of Byte;
    FOutLen, FOutPos: SizeInt;
    FInPos: QWord;
    FStarted, FEof: Boolean;
    function RdByte: Byte;
    function RdVInt: QWord;
    function NextBlock: Boolean;
  public
    constructor Create(ASource: TInStage; ABlockSize: SizeInt);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Block size of the method parameters: b<mem> or a bare memory size; x is accepted and ignored.
  Default 8 MB. }
function DispackBlockSize(const Params: TStringArray): Integer;

{ Whole-buffer helpers (tests): encode Src into a dispack stream and back. }
function XfEncodeBuf(Src: PByte; Len: SizeInt; BlockSize: SizeInt): TBytes;

var
  XfDumpDir: string = '';    // tests: append each stream to <dir>/s<k>.bin and list the regions

implementation

uses
  parc_bytes;

const
  XF_ESC = $D6;              // SALC: undefined in 64-bit mode, unused by compilers
  XF_SUB_LIT = 0;            // ESC 0: the byte D6 itself
  XF_MAXINSN = 64;           // ESC 1..63: that many raw bytes (end of a region)
  XF_MAXPFX = 14;
  XF_SLACK = 32 * 1024;      // free bytes per stream between checks (64 instructions)
  XF_LOOK = 64 * 1024;       // look-ahead for headers that cross a block end
  XF_PAD = 64;               // zero bytes after the plain data (the walker may read past)
  XF_WIN = 4096;             // heuristic window

  { table entries }
  XF_IMM = $0F;
  XF_MODRM = $10;
  XF_PFX = $20;
  XF_0F = $40;
  XF_VEX = $80;
  XI_NONE = 0; XI_B = 1; XI_W = 2; XI_Z = 3; XI_V = 4; XI_ENTER = 5; XI_FAR = 6;
  XI_MOFFS = 7; XI_G3B = 8; XI_G3Z = 9; XI_REL8 = 10; XI_CALL = 11; XI_JMP = 12;

type
  TXfTab = array[0..255] of Byte;
  PXfTab = ^TXfTab;

var
  XfTab32, XfTab64, XfTab0F: TXfTab;

function LoadLE32(P: PByte): LongWord; inline;
begin
{$IFDEF ENDIAN_LITTLE}
  Result := Unaligned(PLongWord(P)^);
{$ELSE}
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
{$ENDIF}
end;

procedure StoreLE32(P: PByte; V: LongWord); inline;
begin
{$IFDEF ENDIAN_LITTLE}
  Unaligned(PLongWord(P)^) := V;
{$ELSE}
  P[0] := Byte(V); P[1] := Byte(V shr 8); P[2] := Byte(V shr 16); P[3] := Byte(V shr 24);
{$ENDIF}
end;

function LoadBE32(P: PByte): LongWord; inline;
begin
  Result := (LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or (LongWord(P[2]) shl 8) or LongWord(P[3]);
end;

procedure StoreBE32(P: PByte; V: LongWord); inline;
begin
  P[0] := Byte(V shr 24); P[1] := Byte(V shr 16); P[2] := Byte(V shr 8); P[3] := Byte(V);
end;

function LoadLE16(P: PByte): LongWord; inline;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8);
end;

{ ---------------------------------------------------------------- opcode tables }

procedure InitTables;
var
  i: Integer;
  procedure S1(Lo, Hi, F: Integer);
  var
    k: Integer;
  begin
    for k := Lo to Hi do
    begin
      XfTab32[k] := F;
      XfTab64[k] := F;
    end;
  end;
  procedure S2(Lo, Hi, F: Integer);
  var
    k: Integer;
  begin
    for k := Lo to Hi do XfTab0F[k] := F;
  end;
begin
  FillChar(XfTab32, SizeOf(XfTab32), 0);
  FillChar(XfTab64, SizeOf(XfTab64), 0);
  FillChar(XfTab0F, SizeOf(XfTab0F), 0);
  { one-byte map }
  for i := 0 to 7 do            // ALU rows 00..3F
  begin
    S1(i * 8, i * 8 + 3, XF_MODRM);
    S1(i * 8 + 4, i * 8 + 4, XI_B);
    S1(i * 8 + 5, i * 8 + 5, XI_Z);
  end;
  XfTab32[$0F] := XF_0F; XfTab64[$0F] := XF_0F;
  S1($26, $26, XF_PFX); S1($2E, $2E, XF_PFX); S1($36, $36, XF_PFX); S1($3E, $3E, XF_PFX);
  for i := $40 to $4F do XfTab64[i] := XF_PFX;          // REX
  XfTab32[$62] := XF_VEX; XfTab64[$62] := XF_VEX;         // BOUND / EVEX
  S1($63, $63, XF_MODRM);
  S1($64, $67, XF_PFX);
  S1($68, $68, XI_Z); S1($69, $69, XF_MODRM or XI_Z);
  S1($6A, $6A, XI_B); S1($6B, $6B, XF_MODRM or XI_B);
  S1($70, $7F, XI_REL8);
  S1($80, $80, XF_MODRM or XI_B); S1($81, $81, XF_MODRM or XI_Z);
  S1($82, $83, XF_MODRM or XI_B);
  S1($84, $8F, XF_MODRM);
  XfTab32[$9A] := XI_FAR;
  S1($A0, $A3, XI_MOFFS);
  S1($A8, $A8, XI_B); S1($A9, $A9, XI_Z);
  S1($B0, $B7, XI_B); S1($B8, $BF, XI_V);
  S1($C0, $C1, XF_MODRM or XI_B); S1($C2, $C2, XI_W);
  S1($C4, $C5, XF_VEX);
  S1($C6, $C6, XF_MODRM or XI_B); S1($C7, $C7, XF_MODRM or XI_Z);
  S1($C8, $C8, XI_ENTER); S1($CA, $CA, XI_W); S1($CD, $CD, XI_B);
  S1($D0, $D3, XF_MODRM);
  XfTab32[$D4] := XI_B; XfTab32[$D5] := XI_B;
  S1($D8, $DF, XF_MODRM);
  S1($E0, $E3, XI_REL8); S1($E4, $E7, XI_B);
  S1($E8, $E8, XI_CALL); S1($E9, $E9, XI_JMP);
  XfTab32[$EA] := XI_FAR;
  S1($EB, $EB, XI_REL8);
  S1($F0, $F0, XF_PFX); S1($F2, $F3, XF_PFX);
  S1($F6, $F6, XF_MODRM or XI_G3B); S1($F7, $F7, XF_MODRM or XI_G3Z);
  S1($FE, $FF, XF_MODRM);
  { two-byte map 0F xx (38 and 3A are handled by the walker) }
  S2($00, $03, XF_MODRM); S2($0D, $0D, XF_MODRM); S2($0F, $0F, XF_MODRM or XI_B);
  S2($10, $2F, XF_MODRM);
  S2($40, $6F, XF_MODRM);
  S2($70, $73, XF_MODRM or XI_B); S2($74, $76, XF_MODRM); S2($78, $7F, XF_MODRM);
  S2($80, $8F, XI_JMP);
  S2($90, $9F, XF_MODRM);
  S2($A3, $A3, XF_MODRM); S2($A4, $A4, XF_MODRM or XI_B); S2($A5, $A5, XF_MODRM);
  S2($AB, $AB, XF_MODRM); S2($AC, $AC, XF_MODRM or XI_B); S2($AD, $AF, XF_MODRM);
  S2($B0, $B9, XF_MODRM); S2($BA, $BA, XF_MODRM or XI_B); S2($BB, $BF, XF_MODRM);
  S2($C0, $C1, XF_MODRM); S2($C2, $C2, XF_MODRM or XI_B); S2($C3, $C3, XF_MODRM);
  S2($C4, $C6, XF_MODRM or XI_B); S2($C7, $C7, XF_MODRM);
  S2($D0, $FF, XF_MODRM);
end;

{ ---------------------------------------------------------------- stream buffers }

procedure XfEnsure(var C: TXfCtx);
var
  s: Integer;
  Used, Cap: SizeInt;
begin
  for s := 0 to XF_NSTREAMS - 1 do
  begin
    Cap := Length(C.Buf[s]);
    if Cap = 0 then Used := 0 else Used := C.P[s] - PByte(@C.Buf[s][0]);
    if Cap - Used < XF_SLACK then
    begin
      Cap := 2 * Cap;
      if Cap < Used + 2 * XF_SLACK then Cap := Used + 2 * XF_SLACK;
      SetLength(C.Buf[s], Cap);
      C.P[s] := PByte(@C.Buf[s][0]) + Used;
    end;
  end;
end;

function XfCheck(const C: TXfCtx): Boolean;
var
  s: Integer;
begin
  for s := 0 to XF_NSTREAMS - 1 do
    if C.P[s] > C.E[s] then Exit(False);
  Result := True;
end;

{ ---------------------------------------------------------------- the walker }

{$DEFINE XF_ENC}
{$MACRO ON}
{$DEFINE XF_NAME:=XfEncodeRegion}
{$I parc_dispack_walk.inc}
{$UNDEF XF_ENC}
{$DEFINE XF_NAME:=XfDecodeRegion}
{$I parc_dispack_walk.inc}

{ ---------------------------------------------------------------- headers }

{ PE at P[0..Avail): code sections of an i386 / AMD64 image that is not .NET }
function ParsePE(P: PByte; Avail: SizeInt; Base: Int64; var Regs: TXfRegionArray; var NRegs: Integer;
  out Span: Int64): Boolean;
var
  Lfa, Opt, Sec, OptSize, NSec, Magic, NDD, i: SizeInt;
  Machine: LongWord;
  ImageBase, VSize, VAddr, RawSize, RawPtr, Chars, Len: LongWord;
  Mode: Byte;
  R: TXfRegion;
  Ends: Int64;
begin
  Result := False;
  Span := 0;
  if Avail < $40 then Exit;
  Lfa := LoadLE32(P + $3C);
  if (Lfa < $40) or (Lfa > XF_LOOK - 256) or (Lfa + 24 + $60 > Avail) then Exit;
  if LoadLE32(P + Lfa) <> $00004550 then Exit;
  Machine := LoadLE16(P + Lfa + 4);
  if Machine = $14C then Mode := 32
  else if Machine = $8664 then Mode := 64
  else Exit;
  NSec := LoadLE16(P + Lfa + 6);
  OptSize := LoadLE16(P + Lfa + 20);
  Opt := Lfa + 24;
  if (NSec < 1) or (NSec > 96) or (OptSize < $60) or (Opt + OptSize + 40 * NSec > Avail) then Exit;
  Magic := LoadLE16(P + Opt);
  if (Magic = $10B) and (Mode = 32) then
  begin
    ImageBase := LoadLE32(P + Opt + 28);
    NDD := LoadLE32(P + Opt + 92);
    if (NDD > 14) and (OptSize >= 96 + 15 * 8) and (LoadLE32(P + Opt + 96 + 14 * 8 + 4) <> 0) then Exit;
  end
  else if (Magic = $20B) and (Mode = 64) then
  begin
    ImageBase := LoadLE32(P + Opt + 24);
    NDD := LoadLE32(P + Opt + 108);
    if (NDD > 14) and (OptSize >= 112 + 15 * 8) and (LoadLE32(P + Opt + 112 + 14 * 8 + 4) <> 0) then Exit;
  end
  else
    Exit;
  Sec := Opt + OptSize;
  Ends := 0;
  for i := 0 to NSec - 1 do
  begin
    VSize := LoadLE32(P + Sec + 40 * i + 8);
    VAddr := LoadLE32(P + Sec + 40 * i + 12);
    RawSize := LoadLE32(P + Sec + 40 * i + 16);
    RawPtr := LoadLE32(P + Sec + 40 * i + 20);
    Chars := LoadLE32(P + Sec + 40 * i + 36);
    if (RawPtr >= 1 shl 30) or (RawSize >= 1 shl 30) then Continue;
    if Int64(RawPtr) + RawSize > Ends then Ends := Int64(RawPtr) + RawSize;
    if Chars and ($20 or $20000000) = 0 then Continue;
    Len := RawSize;
    if (VSize > 0) and (VSize < Len) then Len := VSize;
    if Len < 16 then Continue;
    R.Start := Base + RawPtr;
    R.Len := Len;
    R.Mode := Mode;
    R.Va := ImageBase + VAddr;
    R.ImageBase := ImageBase;
    if NRegs = Length(Regs) then SetLength(Regs, 2 * NRegs + 8);
    Regs[NRegs] := R;
    Inc(NRegs);
    Result := True;
  end;
  Span := Ends;
end;

{ ELF at P[0..Avail): executable PT_LOAD segments of an i386 / x86-64 file }
function ParseELF(P: PByte; Avail: SizeInt; Base: Int64; var Regs: TXfRegionArray; var NRegs: Integer;
  out Span: Int64): Boolean;
var
  Cls, Machine, PhOff, PhEnt, PhNum, i: SizeInt;
  E: PByte;
  Off, Sz, VAddr, Flags, Typ: QWord;
  R: TXfRegion;
  Mode: Byte;
begin
  Result := False;
  Span := 0;
  if (Avail < 64) or (P[5] <> 1) then Exit;
  Cls := P[4];
  Machine := LoadLE16(P + 18);
  if (Cls = 1) and (Machine = 3) then
  begin
    Mode := 32;
    PhOff := LoadLE32(P + 28);
    PhEnt := LoadLE16(P + 42);
    PhNum := LoadLE16(P + 44);
    if PhEnt < 32 then Exit;
  end
  else if (Cls = 2) and (Machine = 62) then
  begin
    Mode := 64;
    if LoadLE32(P + 36) <> 0 then Exit;
    PhOff := LoadLE32(P + 32);
    PhEnt := LoadLE16(P + 54);
    PhNum := LoadLE16(P + 56);
    if PhEnt < 56 then Exit;
  end
  else
    Exit;
  if (PhNum < 1) or (PhNum > 256) or (PhOff < 32) or (PhOff + PhEnt * PhNum > Avail) then Exit;
  for i := 0 to PhNum - 1 do
  begin
    E := P + PhOff + PhEnt * i;
    if Mode = 32 then
    begin
      Typ := LoadLE32(E); Off := LoadLE32(E + 4); VAddr := LoadLE32(E + 8);
      Sz := LoadLE32(E + 16); Flags := LoadLE32(E + 24);
    end
    else
    begin
      Typ := LoadLE32(E); Flags := LoadLE32(E + 4); Off := LoadLE32(E + 8);
      if LoadLE32(E + 12) <> 0 then Continue;
      VAddr := LoadLE32(E + 16);
      Sz := LoadLE32(E + 32);
      if LoadLE32(E + 36) <> 0 then Continue;
    end;
    if Typ <> 1 then Continue;
    if (Off >= 1 shl 31) or (Sz >= 1 shl 31) then Continue;
    if Int64(Off + Sz) > Span then Span := Off + Sz;
    if (Flags and 1 = 0) or (Sz < 16) then Continue;
    R.Start := Base + Int64(Off);
    R.Len := Sz;
    R.Mode := Mode;
    R.Va := LongWord(VAddr);
    R.ImageBase := LongWord(VAddr - Off);
    if NRegs = Length(Regs) then SetLength(Regs, 2 * NRegs + 8);
    Regs[NRegs] := R;
    Inc(NRegs);
    Result := True;
  end;
end;

{ Heuristic for spans without headers: 4 KB windows with many near calls are code. }
procedure HeuristicRegions(P: PByte; Len: SizeInt; Base: Int64; var Regs: TXfRegionArray; var NRegs: Integer);
var
  w, i, e, Calls, Rex, RunStart, RunRex, RunCalls: SizeInt;
  b: Byte;
  R: TXfRegion;

  procedure Flush(EndPos: SizeInt);
  begin
    if (RunStart >= 0) and (EndPos - RunStart >= XF_WIN) then
    begin
      R.Start := Base + RunStart;
      R.Len := EndPos - RunStart;
      if RunRex * 2 > RunCalls then R.Mode := 64 else R.Mode := 32;
      R.Va := LongWord(Base + RunStart);
      R.ImageBase := 0;
        if NRegs = Length(Regs) then SetLength(Regs, 2 * NRegs + 8);
      Regs[NRegs] := R;
      Inc(NRegs);
    end;
    RunStart := -1;
  end;

begin
  RunStart := -1;
  RunRex := 0;
  RunCalls := 0;
  w := 0;
  while w + XF_WIN <= Len do
  begin
    Calls := 0;
    Rex := 0;
    e := w + XF_WIN - 5;
    i := w;
    while i < e do
    begin
      b := P[i];
      if b = $E8 then
      begin
        if (P[i + 4] = 0) or (P[i + 4] = $FF) then Inc(Calls);
      end
      else if (b = $48) or (b = $4C) then
      begin
        case P[i + 1] of
          $89, $8B, $8D, $83, $85, $63, $C7, $81, $39, $3B: Inc(Rex);
        end;
      end;
      Inc(i);
    end;
    if Calls >= 16 then
    begin
      if RunStart < 0 then
      begin
        RunStart := w;
        RunRex := 0;
        RunCalls := 0;
      end;
      Inc(RunRex, Rex);
      Inc(RunCalls, Calls);
    end
    else
      Flush(w);
    Inc(w, XF_WIN);
  end;
  Flush(w);
end;

{ ---------------------------------------------------------------- encoder }

procedure PutVInt(var B: TBytes; var N: SizeInt; V: QWord);
begin
  repeat
    if N >= Length(B) then SetLength(B, 2 * Length(B) + 64);
    if V < $80 then
    begin
      B[N] := V;
      Inc(N);
      Exit;
    end;
    B[N] := (V and $7F) or $80;
    Inc(N);
    V := V shr 7;
  until False;
end;

procedure PutByte(var B: TBytes; var N: SizeInt; V: Byte);
begin
  if N >= Length(B) then SetLength(B, 2 * Length(B) + 64);
  B[N] := V;
  Inc(N);
end;

procedure PutU32(var B: TBytes; var N: SizeInt; V: LongWord);
var
  k: Integer;
begin
  for k := 0 to 3 do PutByte(B, N, Byte(V shr (8 * k)));
end;

function DispackBlockSize(const Params: TStringArray): Integer;
var
  k: Integer;
  p: string;
  m: QWord;
begin
  Result := DISPACK_BLOCK;
  for k := 1 to High(Params) do
  begin
    p := LowerCase(Params[k]);
    if (p = '') or (p = 'x') then Continue;
    if p[1] = 'b' then Delete(p, 1, 1);
    if ParseMemSize(p, m) and (m >= 1) and (m <= XF_MAX_BLOCK) then Result := m;
  end;
end;

constructor TDisPackEncStage.Create(ATarget: TOutStage; ABlockSize: SizeInt);
begin
  inherited Create(ATarget);
  FBlock := ABlockSize;
  if FBlock <= 0 then FBlock := DISPACK_BLOCK;
  if FBlock > XF_MAX_BLOCK then FBlock := XF_MAX_BLOCK;
  FLen := 0;
  FBase := 0;
  FNRegs := 0;
  FNSpans := 0;
end;

procedure TDisPackEncStage.Out(Buf: PByte; Count: SizeInt);
begin
  if Count <= 0 then Exit;
  Emit(Buf, Count);
  Inc(FOutPos, Count);
end;

procedure TDisPackEncStage.AddReg(const R: TXfRegion);
begin
  if FNRegs = Length(FRegs) then SetLength(FRegs, 2 * FNRegs + 8);
  FRegs[FNRegs] := R;
  Inc(FNRegs);
end;

procedure TDisPackEncStage.AddSpan(AStart, ALen: Int64);
begin
  if FNSpans = Length(FSpans) then SetLength(FSpans, 2 * FNSpans + 8);
  FSpans[FNSpans].Start := AStart;
  FSpans[FNSpans].Len := ALen;
  Inc(FNSpans);
end;

procedure TDisPackEncStage.ScanHeaders(N: SizeInt);
var
  i: SizeInt;
  P: PByte;
  Span: Int64;
begin
  P := @FBuf[0];
  for i := 0 to N - 1 do
  begin
    if (P[i] = Ord('M')) and (P[i + 1] = Ord('Z')) then
    begin
      if ParsePE(P + i, FLen - i, FBase + i, FRegs, FNRegs, Span) then AddSpan(FBase + i, Span);
    end
    else if (P[i] = $7F) and (P[i + 1] = Ord('E')) and (P[i + 2] = Ord('L')) and (P[i + 3] = Ord('F')) then
    begin
      if ParseELF(P + i, FLen - i, FBase + i, FRegs, FNRegs, Span) then AddSpan(FBase + i, Span);
    end;
  end;
end;

procedure TDisPackEncStage.DumpBlock(const Rs: TXfRegionArray; NR: Integer; const Len: array of SizeInt);
var
  s, i: Integer;
  F: THandle;
  Fn: string;
begin
  for s := 0 to XF_NSTREAMS - 1 do
  begin
    Fn := XfDumpDir + '/s' + IntToStr(s) + '.bin';
    if FileExists(Fn) then F := FileOpen(Fn, fmOpenWrite) else F := FileCreate(Fn);
    FileSeek(F, 0, fsFromEnd);
    if Len[s] > 0 then FileWrite(F, FCtx.Buf[s][0], Len[s]);
    FileClose(F);
  end;
  for i := 0 to NR - 1 do
    WriteLn(StdErr, Format('region %d+%d mode %d va %x ib %x', [FBase + Rs[i].Start, Rs[i].Len,
      Rs[i].Mode, Rs[i].Va, Rs[i].ImageBase]));
end;

procedure TDisPackEncStage.ProcessBlock(N: SizeInt);
var
  BE: Int64;
  Rs, Hs: TXfRegionArray;
  NR, NH, i, j, k, s: Integer;
  R: TXfRegion;
  Prev, A, Z, GapStart, GapEnd: SizeInt;
  Hdr: TBytes;
  HN: SizeInt;
  Len: array[0..XF_NSTREAMS - 1] of SizeInt;
  Zero: array[0..3] of Byte;
  Raw: PByte;
begin
  BE := FBase + N;
  ScanHeaders(N);

  { regions from headers inside this block, sorted, without overlaps }
  NR := 0;
  SetLength(Rs, FNRegs + 1);
  for i := 0 to FNRegs - 1 do
  begin
    R := FRegs[i];
    if (R.Start >= BE) or (R.Start + R.Len <= FBase) then Continue;
    if R.Start < FBase then
    begin
      Inc(R.Va, LongWord(FBase - R.Start));
      Dec(R.Len, FBase - R.Start);
      R.Start := FBase;
    end;
    if R.Start + R.Len > BE then R.Len := BE - R.Start;
    if R.Len < 16 then Continue;              // the decoder allows at most one region per 16 bytes
    R.Start := R.Start - FBase;
    j := NR;
    while (j > 0) and (Rs[j - 1].Start > R.Start) do
    begin
      Rs[j] := Rs[j - 1];
      Dec(j);
    end;
    Rs[j] := R;
    Inc(NR);
  end;
  { drop overlaps }
  k := 0;
  for i := 0 to NR - 1 do
  begin
    if (k > 0) and (Rs[i].Start < Rs[k - 1].Start + Rs[k - 1].Len) then Continue;
    Rs[k] := Rs[i];
    Inc(k);
  end;
  NR := k;

  { heuristic in the gaps that are not inside an executable found by its header }
  NH := 0;
  Hs := nil;
  Prev := 0;
  for i := 0 to NR do
  begin
    if i < NR then GapEnd := Rs[i].Start else GapEnd := N;
    GapStart := Prev;
    if GapEnd - GapStart >= XF_WIN then
    begin
      { cut out the spans of known executables }
      A := GapStart;
      while A < GapEnd do
      begin
        Z := GapEnd;
        for j := 0 to FNSpans - 1 do
          if (FSpans[j].Start - FBase < Z) and (FSpans[j].Start + FSpans[j].Len - FBase > A) then
          begin
            if FSpans[j].Start - FBase <= A then
            begin
              A := FSpans[j].Start + FSpans[j].Len - FBase;
              if A >= GapEnd then Break;
            end
            else
              Z := FSpans[j].Start - FBase;
          end;
        if A >= GapEnd then Break;
        if Z > GapEnd then Z := GapEnd;
        if Z - A >= XF_WIN then HeuristicRegions(@FBuf[A], Z - A, A, Hs, NH);
        A := Z;
      end;
    end;
    if i < NR then Prev := Rs[i].Start + Rs[i].Len;
  end;
  if NH > 0 then
  begin
    SetLength(Rs, NR + NH);
    for i := 0 to NH - 1 do
    begin
      R := Hs[i];
      R.Va := LongWord(FBase + R.Start);
      j := NR;
      while (j > 0) and (Rs[j - 1].Start > R.Start) do
      begin
        Rs[j] := Rs[j - 1];
        Dec(j);
      end;
      Rs[j] := R;
      Inc(NR);
    end;
  end;

  { encode }
  for s := 0 to XF_NSTREAMS - 1 do
    if Length(FCtx.Buf[s]) > 0 then FCtx.P[s] := @FCtx.Buf[s][0] else FCtx.P[s] := nil;
  XfEnsure(FCtx);
  SetLength(Hdr, 256);
  HN := 0;
  PutVInt(Hdr, HN, N);
  PutVInt(Hdr, HN, NR);
  Prev := 0;
  for i := 0 to NR - 1 do
  begin
    R := Rs[i];
    PutVInt(Hdr, HN, R.Start - Prev);
    PutVInt(Hdr, HN, R.Len);
    PutByte(Hdr, HN, Ord(R.Mode = 64));
    PutU32(Hdr, HN, R.Va);
    { raw gap }
    if R.Start > Prev then
    begin
      if Length(FCtx.Buf[XS_RAW]) - (FCtx.P[XS_RAW] - PByte(@FCtx.Buf[XS_RAW][0])) < R.Start - Prev + XF_SLACK then
      begin
        k := FCtx.P[XS_RAW] - PByte(@FCtx.Buf[XS_RAW][0]);
        SetLength(FCtx.Buf[XS_RAW], k + (R.Start - Prev) + 2 * XF_SLACK);
        FCtx.P[XS_RAW] := PByte(@FCtx.Buf[XS_RAW][0]) + k;
      end;
      Move(FBuf[Prev], FCtx.P[XS_RAW]^, R.Start - Prev);
      Inc(FCtx.P[XS_RAW], R.Start - Prev);
    end;
    XfEnsure(FCtx);
    XfEncodeRegion(FCtx, @FBuf[R.Start], R.Len, R);
    Prev := R.Start + R.Len;
  end;
  if N > Prev then
  begin
    k := FCtx.P[XS_RAW] - PByte(@FCtx.Buf[XS_RAW][0]);
    if Length(FCtx.Buf[XS_RAW]) - k < N - Prev then
    begin
      SetLength(FCtx.Buf[XS_RAW], k + (N - Prev) + XF_SLACK);
      FCtx.P[XS_RAW] := PByte(@FCtx.Buf[XS_RAW][0]) + k;
    end;
    Move(FBuf[Prev], FCtx.P[XS_RAW]^, N - Prev);
    Inc(FCtx.P[XS_RAW], N - Prev);
  end;
  for s := 0 to XF_NSTREAMS - 1 do
  begin
    Len[s] := FCtx.P[s] - PByte(@FCtx.Buf[s][0]);
    PutVInt(Hdr, HN, Len[s]);
  end;

  if XfDumpDir <> '' then DumpBlock(Rs, NR, Len);

  { write }
  FillChar(Zero, SizeOf(Zero), 0);
  if not FHeaderDone then
  begin
    Zero[0] := XF_VERSION;
    Out(@Zero[0], 1);
    Zero[0] := 0;
    FHeaderDone := True;
  end;
  Out(@Hdr[0], HN);
  Out(@Zero[0], (4 - FOutPos and 3) and 3);
  for s := 0 to XF_NSTREAMS - 1 do
  begin
    Out(@FCtx.Buf[s][0], Len[s]);
    Out(@Zero[0], (4 - FOutPos and 3) and 3);
  end;

  { drop the block }
  Raw := @FBuf[0];
  Move(Raw[N], Raw[0], FLen - N);
  Dec(FLen, N);
  FBase := BE;
  FillChar(Raw[FLen], XF_PAD, 0);
  k := 0;
  for i := 0 to FNRegs - 1 do
    if FRegs[i].Start + FRegs[i].Len > FBase then
    begin
      FRegs[k] := FRegs[i];
      Inc(k);
    end;
  FNRegs := k;
  k := 0;
  for i := 0 to FNSpans - 1 do
    if FSpans[i].Start + FSpans[i].Len > FBase then
    begin
      FSpans[k] := FSpans[i];
      Inc(k);
    end;
  FNSpans := k;
end;

procedure TDisPackEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  if Length(FBuf) = 0 then SetLength(FBuf, FBlock + XF_LOOK + XF_PAD);
  while Count > 0 do
  begin
    n := FBlock + XF_LOOK - FLen;
    if n > Count then n := Count;
    Move(Buf^, FBuf[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FLen = FBlock + XF_LOOK then
    begin
      FillChar(FBuf[FLen], XF_PAD, 0);
      ProcessBlock(FBlock);
    end;
  end;
end;

procedure TDisPackEncStage.DoFinish;
var
  n: SizeInt;
begin
  if FLen > 0 then FillChar(FBuf[FLen], XF_PAD, 0);
  while FLen > 0 do
  begin
    n := FLen;
    if n > FBlock then n := FBlock;
    ProcessBlock(n);
  end;
  inherited DoFinish;
end;

function XfEncodeBuf(Src: PByte; Len: SizeInt; BlockSize: SizeInt): TBytes;
var
  Sink: TMemSink;
  St: TDisPackEncStage;
begin
  Sink := TMemSink.Create;
  St := TDisPackEncStage.Create(Sink, BlockSize);
  try
    if Len > 0 then St.Write(Src, Len);
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;
  end;
end;

{ ---------------------------------------------------------------- decoder }

constructor TDisPackStage.Create(ASource: TInStage; ABlockSize: SizeInt);
begin
  inherited Create(ASource);
  FMaxBlock := ABlockSize;
  if FMaxBlock <= 0 then FMaxBlock := DISPACK_BLOCK;
end;

function TDisPackStage.RdByte: Byte;
begin
  Source.ReadExact(@Result, 1);
  Inc(FInPos);
end;

function TDisPackStage.RdVInt: QWord;
var
  b: Byte;
  Sh: Integer;
begin
  Result := 0;
  Sh := 0;
  repeat
    b := RdByte;
    if Sh >= 63 then Corrupt('dispack: bad number');
    Result := Result or (QWord(b and $7F) shl Sh);
    Inc(Sh, 7);
  until b < $80;
end;

function TDisPackStage.NextBlock: Boolean;
var
  b: Byte;
  N, NReg, Gap, RLen, Pad, Total, Pos, RawLeft: QWord;
  Regs: TXfRegionArray;
  Lens: array[0..XF_NSTREAMS - 1] of QWord;
  i, s: Integer;
  C: TXfCtx;
  P: PByte;
  Prev: SizeInt;
begin
  Result := False;
  if not FStarted then
  begin
    FStarted := True;
    if not Source.ReadExactOrEof(@b, 1) then
    begin
      FEof := True;
      Exit;
    end;
    Inc(FInPos);
    if b <> XF_VERSION then Corrupt('dispack: unknown stream version');
  end;
  if not Source.ReadExactOrEof(@b, 1) then
  begin
    FEof := True;
    Exit;
  end;
  Inc(FInPos);
  { VInt N, first byte already read }
  N := b and $7F;
  if b >= $80 then N := N or (RdVInt shl 7);
  if (N < 1) or (N > QWord(FMaxBlock)) then Corrupt('dispack: bad block size');
  NReg := RdVInt;
  if NReg > N div 16 + 1 then Corrupt('dispack: bad region count');
  SetLength(Regs, NReg);
  Pos := 0;
  for i := 0 to NReg - 1 do
  begin
    Gap := RdVInt;
    RLen := RdVInt;
    if (Gap > N - Pos) or (RLen < 1) or (RLen > N - Pos - Gap) then Corrupt('dispack: bad region');
    Regs[i].Start := Pos + Gap;
    Regs[i].Len := RLen;
    Pos := Pos + Gap + RLen;
    b := RdByte;
    if b > 1 then Corrupt('dispack: bad region mode');
    Regs[i].Mode := 32 + 32 * b;
    Source.ReadExact(@Regs[i].Va, 4);
    Inc(FInPos, 4);
{$IFDEF ENDIAN_BIG}
    Regs[i].Va := SwapEndian(Regs[i].Va);
{$ENDIF}
  end;
  Total := 0;
  for s := 0 to XF_NSTREAMS - 1 do
  begin
    Lens[s] := RdVInt;
    if Lens[s] > 2 * N + 64 then Corrupt('dispack: bad stream size');
    Total := Total + (Lens[s] + 3) and not QWord(3);
  end;
  if Total > 4 * N + 4096 then Corrupt('dispack: bad stream sizes');
  Pad := (4 - FInPos and 3) and 3;
  if Length(FIn) < Total + Pad + XF_SLACK then SetLength(FIn, Total + Pad + XF_SLACK);
  Source.ReadExact(@FIn[0], Total + Pad);
  Inc(FInPos, Total + Pad);
  FillChar(FIn[Total + Pad], XF_SLACK, 0);
  for i := 0 to Pad - 1 do
    if FIn[i] <> 0 then Corrupt('dispack: bad padding');
  P := @FIn[Pad];
  for s := 0 to XF_NSTREAMS - 1 do
  begin
    C.P[s] := P;
    C.E[s] := P + Lens[s];
    for i := Lens[s] to ((Lens[s] + 3) and not QWord(3)) - 1 do
      if P[i] <> 0 then Corrupt('dispack: bad padding');
    Inc(P, (Lens[s] + 3) and not QWord(3));
  end;

  if Length(FOut) < N + XF_PAD then SetLength(FOut, N + XF_PAD);
  Prev := 0;
  for i := 0 to NReg do
  begin
    if i < NReg then RLen := Regs[i].Start - Prev else RLen := N - Prev;
    RawLeft := C.E[XS_RAW] - C.P[XS_RAW];
    if RLen > RawLeft then Corrupt('dispack: raw stream too short');
    Move(C.P[XS_RAW]^, FOut[Prev], RLen);
    Inc(C.P[XS_RAW], RLen);
    if i = NReg then Break;
    if not XfDecodeRegion(C, @FOut[Regs[i].Start], Regs[i].Len, Regs[i]) then
      Corrupt('dispack: damaged code stream');
    Prev := Regs[i].Start + Regs[i].Len;
  end;
  for s := 0 to XF_NSTREAMS - 1 do
    if C.P[s] <> C.E[s] then Corrupt('dispack: stream size mismatch');
  FOutLen := N;
  FOutPos := 0;
  Result := True;
end;

function TDisPackStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := 0;
  while Count > 0 do
  begin
    if FOutPos >= FOutLen then
    begin
      if FEof or not NextBlock then Break;
    end;
    n := FOutLen - FOutPos;
    if n > Count then n := Count;
    Move(FOut[FOutPos], Buf^, n);
    Inc(FOutPos, n);
    Inc(Buf, n);
    Inc(Result, n);
    Dec(Count, n);
  end;
end;

initialization
  InitTables;
end.
