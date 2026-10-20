{ DisPack 0.70 (Compression/DisPack/DisPack.cpp): filtro para código x86 antes de comprimir.
  Desarma el flujo de instrucciones en "streams" (opcodes, ModRM, desplazamientos, inmediatos,
  destinos de call/jump) y convierte los destinos relativos en absolutos, con una tabla de
  funciones por move-to-front. Es reversible byte a byte: un opcode que no se entiende se
  guarda con el escape 0xF1.

  El bloque guardado es el flujo de DISPACK_METHOD (C_DisPack.cpp): [CHUNK_SIZE u32] y después
  tramos con tag: TAG_DATA (datos tal cual) o TAG_EXE (un tramo filtrado con DisPackFilter). }
unit parc_dispack;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, parc_stream, parc_bytes;

const
  DISPACK_TAG_DATA = $C71B3AE1;
  DISPACK_TAG_EXE  = $C71B3AE2;
  DISPACK_CHUNK    = 16 * 1024;            // CHUNK_SIZE de C_DisPack.cpp
  DISPACK_BLOCK    = 8 * 1024 * 1024;      // BlockSize por defecto

{ Filtra Src (Origin = dirección base del tramo) y devuelve el flujo de streams. }
function DisPackFilter(Src: PByte; SrcLen: Integer; Origin: LongWord; out OutLen: Integer): TBytes;

{ Deshace DisPackFilter: DstLen tiene que ser el tamaño original. }
function DisPackUnFilter(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Integer; Memory: LongWord): Boolean;

{ Bloque completo, como DISPACK_METHOD::compress/decompress. }
function DispackEncode(Src: PByte; SrcLen: Integer; BlockSize: Integer): TBytes;

{ BlockSize de los parámetros de dispack (parse_DISPACK: :b<mem>, o una memoria suelta;
  :x queda en el texto pero no cambia el flujo). Default 8 MB. }
function DispackBlockSize(const Params: TStringArray): Integer;
function DispackDecode(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Integer; BlockSize: Integer): Boolean;

type
  { Descomprime un bloque dispack (wrapper) como un stream. }
  TDisPackStage = class(TInStage)
  private
    FData: TBytes;
    FLen, FPos: Integer;
    FChunkSize, FBlockSize: LongWord;
    FBase: LongWord;
    FStarted: Boolean;
    FOut: TBytes;
    FOutPos, FOutLen: Integer;
    function NextPiece: Boolean;
  public
    constructor Create(ASource: TInStage; ABlockSize: LongWord);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

implementation

const
  MAXINSTR = 15;
  ST_OP = 0;
  ST_SIB = 1;
  ST_CALL_IDX = 2;
  ST_DISP8_R0 = 3;                 // .. ST_DISP8_R0+7
  ST_JUMP8 = 11;
  ST_IMM8 = 12;
  ST_IMM16 = 13;
  ST_IMM32 = 14;
  ST_DISP32 = 15;
  ST_ADDR32 = 16;
  ST_CALL32 = 17;
  ST_JUMP32 = 18;
  ST_MAX = 19;
  ST_MODRM = ST_OP;
  ST_OP2 = ST_OP;
  ST_AJUMP32 = ST_JUMP32;
  ST_JUMPTBL_COUNT = ST_OP;

  fNM = $0; fAM = $1; fMR = $2; fMEXTRA = $3; fMODE = $3;
  fNI = $0; fBI = $4; fWI = $8; fDI = $c; fTYPE = $c;
  fAD = $0; fDA = $4; fBR = $8; fDR = $c; fERR = $f;

  OP_2BYTE = $0f; OP_OSIZE = $66; OP_CALLF = $9a; OP_RETNI = $c2; OP_RETN = $c3;
  OP_ENTER = $c8; OP_INT3 = $cc; OP_INTO = $ce; OP_CALLN = $e8; OP_JMPF = $ea; OP_ICEBP = $f1;
  ESCAPE = OP_ICEBP;
  JUMPTAB = OP_INTO;

  Table1: array[0..255] of Byte = (
$02,$02,$02,$02,$04,$0c,$00,$00,$02,$02,$02,$02,$04,$0c,$00,$00,
$02,$02,$02,$02,$04,$0c,$00,$00,$02,$02,$02,$02,$04,$0c,$00,$00,
$02,$02,$02,$02,$04,$0c,$00,$00,$02,$02,$02,$02,$04,$0c,$00,$00,
$02,$02,$02,$02,$04,$0c,$00,$00,$02,$02,$02,$02,$04,$0c,$00,$00,
$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,
$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,
$00,$00,$02,$02,$00,$00,$00,$00,$0c,$0e,$04,$06,$00,$00,$00,$00,
$09,$09,$09,$09,$09,$09,$09,$09,$09,$09,$09,$09,$09,$09,$09,$09,
$06,$0e,$06,$06,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,
$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$05,$00,$00,$00,$00,$00,
$01,$01,$01,$01,$00,$00,$00,$00,$04,$0c,$00,$00,$00,$00,$00,$00,
$04,$04,$04,$04,$04,$04,$04,$04,$0c,$0c,$0c,$0c,$0c,$0c,$0c,$0c,
$06,$06,$08,$00,$02,$02,$06,$0e,$04,$00,$08,$00,$00,$04,$0f,$00,
$02,$02,$02,$02,$04,$04,$00,$00,$02,$02,$02,$02,$02,$02,$02,$02,
$09,$09,$09,$09,$04,$04,$04,$04,$0d,$0d,$01,$09,$00,$00,$00,$00,
$00,$0f,$00,$00,$00,$00,$03,$03,$00,$00,$00,$00,$00,$00,$03,$03);

  Table2: array[0..255] of Byte = (
$0f,$0f,$0f,$0f,$0f,$0f,$00,$0f,$00,$00,$0f,$0f,$0f,$0f,$0f,$0f,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$0f,$0f,$0f,$0f,$0f,$0f,$0f,
$02,$02,$02,$02,$0f,$0f,$0f,$0f,$02,$02,$02,$02,$02,$02,$02,$02,
$00,$00,$00,$00,$00,$00,$0f,$00,$0f,$0f,$0f,$0f,$0f,$0f,$0f,$0f,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,
$06,$06,$06,$06,$02,$02,$02,$00,$0f,$0f,$0f,$0f,$0f,$0f,$02,$02,
$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,$0d,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,
$00,$00,$00,$02,$06,$02,$02,$02,$0f,$0f,$0f,$02,$06,$02,$0f,$02,
$02,$02,$02,$02,$02,$02,$02,$02,$0f,$0f,$0f,$02,$02,$02,$02,$02,
$02,$02,$02,$02,$02,$02,$02,$02,$00,$00,$00,$00,$00,$00,$00,$00,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,
$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$02,$0f);

  TableX: array[0..31] of Byte = (
$06,$0f,$02,$02,$02,$02,$02,$02,$0e,$0f,$02,$02,$02,$02,$02,$02,
$02,$02,$0f,$0f,$0f,$0f,$0f,$0f,$02,$02,$02,$0f,$02,$0f,$02,$0f);

function IsTag(V: LongWord): Boolean; inline;
begin
  Result := (V xor DISPACK_TAG_DATA) < $10;
end;

type
  TByteBuf = record
    Data: TBytes;
    Len, Cap: Integer;
  end;

function Load16LE(P: PByte): Word; inline;
begin
  Result := Word(P[0]) or (Word(P[1]) shl 8);
end;

function Load32LE(P: PByte): LongWord; inline;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

function Load16BE(P: PByte): Word; inline;
begin
  Result := (Word(P[0]) shl 8) or Word(P[1]);
end;

function Load32BE(P: PByte): LongWord; inline;
begin
  Result := (LongWord(P[0]) shl 24) or (LongWord(P[1]) shl 16) or (LongWord(P[2]) shl 8) or LongWord(P[3]);
end;

procedure Store16LE(P: PByte; V: Word); inline;
begin
  P[0] := Byte(V and $FF); P[1] := Byte((V shr 8) and $FF);
end;

procedure Store32LE(P: PByte; V: LongWord); inline;
begin
  P[0] := Byte(V and $FF); P[1] := Byte((V shr 8) and $FF);
  P[2] := Byte((V shr 16) and $FF); P[3] := Byte((V shr 24) and $FF);
end;

procedure Buf8(var B: TByteBuf; V: Byte); inline;
begin
  if B.Len = B.Cap then
  begin
    if B.Cap = 0 then B.Cap := 256 else B.Cap := B.Cap * 2;
    SetLength(B.Data, B.Cap);
  end;
  B.Data[B.Len] := V;
  Inc(B.Len);
end;

procedure Buf16B(var B: TByteBuf; V: Word); inline;   // big endian
begin
  Buf8(B, Byte(V shr 8));
  Buf8(B, Byte(V));
end;

procedure Buf32B(var B: TByteBuf; V: LongWord); inline;   // big endian
begin
  Buf8(B, Byte(V shr 24));
  Buf8(B, Byte(V shr 16));
  Buf8(B, Byte(V shr 8));
  Buf8(B, Byte(V));
end;

function DisPackFilter(Src: PByte; SrcLen: Integer; Origin: LongWord; out OutLen: Integer): TBytes;
var
  Buf: array[0..ST_MAX - 1] of TByteBuf;
  FuncTable: array[0..255] of LongWord;
  NextIsFunc: Boolean;
  CodeStart, CodeEnd: LongWord;
  Sizes: array[0..ST_MAX - 1] of Integer;
  Pos, Used, I, Total: Integer;
  CurAvail, Cur: Integer;
  CurP: PByte;
  CurFail: Boolean;

  procedure Put8(St: Integer; V: Byte); inline;
  begin Buf8(Buf[St], V); end;

  procedure Put16(St: Integer; V: Word); inline;
  begin Buf16B(Buf[St], V); end;

  procedure Put32(St: Integer; V: LongWord); inline;
  begin Buf32B(Buf[St], V); end;

  function Take8: Byte;
  begin
    if Cur >= CurAvail then begin CurFail := True; Result := 0; end
    else begin Result := CurP[Cur]; Inc(Cur); end;
  end;

  function Take16LE: Word;
  begin
    if Cur + 2 > CurAvail then begin CurFail := True; Result := 0; end
    else begin Result := Load16LE(CurP + Cur); Inc(Cur, 2); end;
  end;

  function Take32LE: LongWord;
  begin
    if Cur + 4 > CurAvail then begin CurFail := True; Result := 0; end
    else begin Result := Load32LE(CurP + Cur); Inc(Cur, 4); end;
  end;

  procedure Copy8(St: Integer); inline;
  begin Put8(St, Take8); end;

  procedure Copy16(St: Integer); inline;
  begin Put16(St, Take16LE); end;

  procedure Copy32(St: Integer); inline;
  begin Put32(St, Take32LE); end;

  procedure MoveToFront(Pos: Integer; Val: LongWord); inline;
  begin
    while Pos > 0 do
    begin
      FuncTable[Pos] := FuncTable[Pos - 1];
      Dec(Pos);
    end;
    FuncTable[0] := Val;
  end;

  procedure AddMTF(Val: LongWord); inline;
  begin MoveToFront(255, Val); end;

  function FindMTF(Val: LongWord): Integer;
  var i: Integer;
  begin
    for i := 0 to 254 do
      if FuncTable[i] = Val then
      begin
        MoveToFront(i, Val);
        Exit(i);
      end;
    AddMTF(Val);
    Result := -1;
  end;

  function DetectJumpTable(P: PByte; Avail: Integer; Addr: LongWord): Integer;
  var nMax, Count: Integer; Coded: LongWord;
  begin
    Result := 0;
    nMax := Integer((CodeEnd - Addr) div 4);
    if nMax > Avail div 4 then nMax := Avail div 4;
    Count := 0;
    while Count < nMax do
    begin
      Coded := Load32LE(P + Count * 4);
      if (Coded >= CodeStart) and (Coded < CodeEnd) then Inc(Count) else Break;
    end;
    if Count < 3 then Count := 0;
    Result := Count;
  end;

  function ProcessInstr(P: PByte; Avail: Integer; Memory: LongWord; out BytesUsed: Integer): Boolean;
  var
    NJump, Count, Remaining, I2, JCur, Idx, Code, Code2, Flags, ModRM, Sib: Integer;
    O16: Boolean;
    Target, Coded: LongWord;
  begin
    BytesUsed := 0;
    NJump := DetectJumpTable(P, Avail, Memory);
    if NJump > 0 then
    begin
      Remaining := NJump;
      JCur := 0;
      while Remaining > 0 do
      begin
        if Remaining < 256 then Count := Remaining else Count := 256;
        Put8(ST_OP, JUMPTAB);
        Put8(ST_JUMPTBL_COUNT, Byte(Count - 1));
        for I2 := 0 to Count - 1 do
        begin
          Coded := Load32LE(P + JCur);
          Inc(JCur, 4);
          Idx := FindMTF(Coded);
          Put8(ST_CALL_IDX, Byte(Idx + 1));
          if Idx = -1 then Put32(ST_CALL32, Coded);
        end;
        Dec(Remaining, Count);
      end;
      BytesUsed := NJump * 4;
      Exit(True);
    end;

    CurP := P; CurAvail := Avail; Cur := 0; CurFail := False;

    Code := Take8;
    Code2 := 0;
    O16 := False;
    if CurFail then Exit(False);

    if NextIsFunc and (Code <> OP_INT3) then
    begin
      AddMTF(Memory);
      NextIsFunc := False;
    end;

    if Code = OP_OSIZE then
    begin
      O16 := True;
      Code := Take8;
      if CurFail then Exit(False);
    end;

    if Code = OP_2BYTE then
    begin
      Code2 := Take8;
      if CurFail then Exit(False);
      Flags := Table2[Code2];
    end
    else
      Flags := Table1[Code];

    if (Code = OP_RETNI) or (Code = OP_RETN) or (Code = OP_INT3) then
      NextIsFunc := True;

    if Flags = fMEXTRA then
    begin
      // usa el ModRM que viene, sin consumirlo (parse_4x4: *instr)
      if Cur >= CurAvail then Exit(False);
      Flags := TableX[((P[Cur] shr 3) and 7) or ((Code and $01) shl 3) or ((Code and $08) shl 1)];
    end;

    if Flags <> fERR then
    begin
      if O16 then Put8(ST_OP, OP_OSIZE);
      Put8(ST_OP, Code);
      if Code = OP_2BYTE then Put8(ST_OP2, Code2);

      if (Code = OP_CALLF) or (Code = OP_JMPF) or (Code = OP_ENTER) then
        Copy16(ST_IMM16);

      if (Flags and fMODE) = fMR then
      begin
        ModRM := Take8;
        if CurFail then Exit(False);
        Put8(ST_MODRM, ModRM);
        Sib := 0;
        if ((ModRM and $07) = 4) and (ModRM < $c0) then
        begin
          Sib := Take8;
          if CurFail then Exit(False);
          Put8(ST_SIB, Sib);
        end;
        if (ModRM and $c0) = $40 then Copy8(ST_DISP8_R0 + (ModRM and $07));
        if ((ModRM and $c0) = $80) or ((ModRM and $c7) = $05) or
           ((ModRM < $40) and ((Sib and $07) = 5)) then
        begin
          if (ModRM and $c7) = $05 then Copy32(ST_ADDR32) else Copy32(ST_DISP32);
        end;
      end;

      if (Flags and fMODE) = fAM then
      begin
        case Flags and fTYPE of
          fAD: Copy32(ST_ADDR32);
          fDA: Copy32(ST_AJUMP32);
          fBR: Copy8(ST_JUMP8);
          fDR:
            begin
              Target := Take32LE;
              if CurFail then Exit(False);
              Inc(Target, LongWord(Cur) + Memory);   // (instr - start) = Cur después del fetch
              if Code <> OP_CALLN then
                Put32(ST_JUMP32, Target)
              else
              begin
                Idx := FindMTF(Target);
                Put8(ST_CALL_IDX, Byte(Idx + 1));
                if Idx = -1 then Put32(ST_CALL32, Target);
              end;
            end;
        end;
      end
      else
        case Flags and fTYPE of
          fBI: Copy8(ST_IMM8);
          fWI: Copy16(ST_IMM16);
          fDI:
            if not O16 then Copy32(ST_IMM32) else Copy16(ST_IMM16);
        end;

      if CurFail then Exit(False);
      BytesUsed := Cur;
      Exit(True);
    end
    else
    begin
      Put8(ST_OP, ESCAPE);
      Put8(ST_OP, P[0]);
      BytesUsed := 1;
      Exit(True);
    end;
  end;

  procedure SaveCheckpoints;
  var i: Integer;
  begin
    for i := 0 to ST_MAX - 1 do Sizes[i] := Buf[i].Len;
  end;

  procedure RestoreCheckpoints;
  var i: Integer;
  begin
    for i := 0 to ST_MAX - 1 do Buf[i].Len := Sizes[i];
  end;

begin
  Result := nil;
  for I := 0 to ST_MAX - 1 do
  begin
    Buf[I].Data := nil; Buf[I].Len := 0; Buf[I].Cap := 0;
  end;
  FillChar(FuncTable, SizeOf(FuncTable), 0);
  NextIsFunc := True;
  CodeStart := Origin;
  CodeEnd := Origin + LongWord(SrcLen);

  Pos := 0;
  if SrcLen > MAXINSTR then
    while Pos < SrcLen - MAXINSTR do
    begin
      if not ProcessInstr(Src + Pos, SrcLen - Pos, Origin + LongWord(Pos), Used) then Break;
      Inc(Pos, Used);
    end;

  // Últimos bytes: si una instrucción se pasa del final, se deshace y se guarda como escape.
  while Pos < SrcLen do
  begin
    SaveCheckpoints;
    if not ProcessInstr(Src + Pos, SrcLen - Pos, Origin + LongWord(Pos), Used) or (Pos + Used > SrcLen) then
    begin
      RestoreCheckpoints;
      Break;
    end;
    Inc(Pos, Used);
  end;

  while Pos < SrcLen do
  begin
    Put8(ST_OP, ESCAPE);
    Put8(ST_OP, Src[Pos]);
    Inc(Pos);
  end;

  Total := ST_MAX * 4;
  for I := 0 to ST_MAX - 1 do Inc(Total, Buf[I].Len);
  SetLength(Result, Total);
  for I := 0 to ST_MAX - 1 do Store32LE(@Result[I * 4], LongWord(Buf[I].Len));
  Total := ST_MAX * 4;
  for I := 0 to ST_MAX - 1 do
  begin
    if Buf[I].Len > 0 then Move(Buf[I].Data[0], Result[Total], Buf[I].Len);
    Inc(Total, Buf[I].Len);
  end;
  OutLen := Length(Result);
end;

function DisPackUnFilter(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Integer; Memory: LongWord): Boolean;
var
  Stream, StreamEnd: array[0..ST_MAX - 1] of Integer;
  FuncTable: array[0..255] of LongWord;
  NextIsFunc: Boolean;
  Hdr, Cur, OutPos, Code, Code2, Flags, ModRM, Sib, Idx, Count, I: Integer;
  O16: Boolean;
  Target, Mem: LongWord;

  procedure MoveToFront(Pos: Integer; Val: LongWord);
  begin
    while Pos > 0 do
    begin
      FuncTable[Pos] := FuncTable[Pos - 1];
      Dec(Pos);
    end;
    FuncTable[0] := Val;
  end;

  procedure AddMTF(Val: LongWord); inline;
  begin MoveToFront(255, Val); end;

  function SrcRoom(St, N: Integer): Boolean; inline;
  begin Result := Stream[St] + N <= StreamEnd[St]; end;

  function DstRoom(N: Integer): Boolean; inline;
  begin Result := OutPos + N <= DstLen; end;

  function GetStream8(St: Integer; out V: Integer): Boolean;
  begin
    if not SrcRoom(St, 1) then Exit(False);
    V := Src[Stream[St]]; Inc(Stream[St]); Result := True;
  end;

  function GetStream16B(St: Integer; out V: Word): Boolean;
  begin
    if not SrcRoom(St, 2) then Exit(False);
    V := Load16BE(Src + Stream[St]); Inc(Stream[St], 2); Result := True;
  end;

  function GetStream32B(St: Integer; out V: LongWord): Boolean;
  begin
    if not SrcRoom(St, 4) then Exit(False);
    V := Load32BE(Src + Stream[St]); Inc(Stream[St], 4); Result := True;
  end;

  function PutOut8(V: Byte): Boolean;
  begin
    if not DstRoom(1) then Exit(False);
    Dst[OutPos] := V; Inc(OutPos); Result := True;
  end;

  function PutOut16LE(V: Word): Boolean;
  begin
    if not DstRoom(2) then Exit(False);
    Store16LE(Dst + OutPos, V); Inc(OutPos, 2); Result := True;
  end;

  function PutOut32LE(V: LongWord): Boolean;
  begin
    if not DstRoom(4) then Exit(False);
    Store32LE(Dst + OutPos, V); Inc(OutPos, 4); Result := True;
  end;

  function CopyStream8(St: Integer): Boolean;
  var V: Integer;
  begin
    Result := GetStream8(St, V) and PutOut8(V);
  end;

  function CopyStream16(St: Integer): Boolean;
  var V: Word;
  begin
    Result := GetStream16B(St, V) and PutOut16LE(V);
  end;

  function CopyStream32(St: Integer): Boolean;
  var V: LongWord;
  begin
    Result := GetStream32B(St, V) and PutOut32LE(V);
  end;

  function TakeMTF(Idx: Integer; out Target: LongWord): Boolean;
  begin
    Result := True;
    if Idx <> 0 then
    begin
      Target := FuncTable[Idx - 1];
      MoveToFront(Idx - 1, Target);
    end
    else if GetStream32B(ST_CALL32, Target) then
      AddMTF(Target)
    else
      Result := False;
  end;

var
  StartPos: Integer;
begin
  Result := False;
  if SrcLen < ST_MAX * 4 then Exit;

  Hdr := 0;
  Cur := ST_MAX * 4;
  for I := 0 to ST_MAX - 1 do
  begin
    Stream[I] := Cur;
    Inc(Cur, Integer(Load32LE(Src + Hdr)));
    Inc(Hdr, 4);
    if Cur > SrcLen then Exit;
    StreamEnd[I] := Cur;
  end;
  if Cur <> SrcLen then Exit;

  FillChar(FuncTable, SizeOf(FuncTable), 0);
  NextIsFunc := True;
  OutPos := 0;

  while Stream[ST_OP] < StreamEnd[ST_OP] do
  begin
    StartPos := OutPos;
    Mem := Memory + LongWord(OutPos);

    if not GetStream8(ST_OP, Code) then Exit;
    if Code = JUMPTAB then
    begin
      if not GetStream8(ST_JUMPTBL_COUNT, Count) then Exit;
      Inc(Count);
      for I := 0 to Count - 1 do
      begin
        if not GetStream8(ST_CALL_IDX, Idx) then Exit;
        if not TakeMTF(Idx, Target) then Exit;
        if not PutOut32LE(Target) then Exit;
      end;
      Continue;
    end;

    if NextIsFunc and (Code <> OP_INT3) then
    begin
      AddMTF(Mem);
      NextIsFunc := False;
    end;

    if Code = ESCAPE then
    begin
      if not CopyStream8(ST_OP) then Exit;
      Continue;
    end;

    if not PutOut8(Byte(Code)) then Exit;

    Flags := 0;
    O16 := False;
    if Code = OP_OSIZE then
    begin
      O16 := True;
      if not GetStream8(ST_OP, Code) then Exit;
      if not PutOut8(Byte(Code)) then Exit;
    end;

    if (Code = OP_RETNI) or (Code = OP_RETN) or (Code = OP_INT3) then
      NextIsFunc := True;

    if Code = OP_2BYTE then
    begin
      if not GetStream8(ST_OP2, Code2) then Exit;
      if not PutOut8(Byte(Code2)) then Exit;
      Flags := Table2[Code2];
    end
    else
      Flags := Table1[Code];

    if (Code = OP_CALLF) or (Code = OP_JMPF) or (Code = OP_ENTER) then
      if not CopyStream16(ST_IMM16) then Exit;

    if (Flags and fMR) <> 0 then
    begin
      if not GetStream8(ST_MODRM, ModRM) then Exit;
      if not PutOut8(Byte(ModRM)) then Exit;
      Sib := 0;
      if Flags = fMEXTRA then
        Flags := TableX[((ModRM shr 3) and 7) or ((Code and $01) shl 3) or ((Code and $08) shl 1)];
      if ((ModRM and $07) = 4) and (ModRM < $c0) then
      begin
        if not GetStream8(ST_SIB, Sib) then Exit;
        if not PutOut8(Byte(Sib)) then Exit;
      end;
      if (ModRM and $c0) = $40 then
        if not CopyStream8(ST_DISP8_R0 + (ModRM and $07)) then Exit;
      if ((ModRM and $c0) = $80) or ((ModRM and $c7) = $05) or
         ((ModRM < $40) and ((Sib and $07) = 5)) then
      begin
        if (ModRM and $c7) = 5 then
        begin
          if not CopyStream32(ST_ADDR32) then Exit;
        end
        else if not CopyStream32(ST_DISP32) then Exit;
      end;
    end;

    if (Flags and fMODE) = fAM then
    begin
      case Flags and fTYPE of
        fAD: if not CopyStream32(ST_ADDR32) then Exit;
        fDA: if not CopyStream32(ST_AJUMP32) then Exit;
        fBR: if not CopyStream8(ST_JUMP8) then Exit;
        fDR:
          begin
            if Code = OP_CALLN then
            begin
              if not GetStream8(ST_CALL_IDX, Idx) then Exit;
              if not TakeMTF(Idx, Target) then Exit;
            end
            else if not GetStream32B(ST_JUMP32, Target) then Exit;
            Dec(Target, LongWord(OutPos - StartPos) + 4 + Mem);
            if not PutOut32LE(Target) then Exit;
          end;
      end;
    end
    else
      case Flags and fTYPE of
        fBI: if not CopyStream8(ST_IMM8) then Exit;
        fWI: if not CopyStream16(ST_IMM16) then Exit;
        fDI:
          if not O16 then
          begin
            if not CopyStream32(ST_IMM32) then Exit;
          end
          else if not CopyStream16(ST_IMM16) then Exit;
      end;
  end;

  Result := OutPos = DstLen;
end;

{ detect (C_DisPack.cpp): ¿el tramo parece código de ejecutable? }
function DetectExe(P: PByte; Len: Integer): Boolean;
var
  e8, exe, obj, i: Integer;
begin
  Result := False;
  if Len <= 0 then Exit;
  e8 := 0; exe := 0; obj := 0;
  i := 0;
  while i + 5 < Len do
  begin
    if P[i] = $E8 then
    begin
      Inc(e8);
      if (P[i + 4] = $FF) and (P[i + 5] <> $FF) then Inc(exe);
      if (P[i + 4] = 0) and (P[i + 5] <> 0) then Inc(obj);
    end;
    Inc(i);
  end;
  if e8 = 0 then Exit;
  Result := (e8 / Len >= 0.002) and ((exe + obj) / e8 >= 0.20) and (exe / e8 >= 0.01);
end;

procedure BufRaw(var B: TByteBuf; P: PByte; N: Integer); inline;
begin
  if N <= 0 then Exit;
  if B.Len + N > B.Cap then
  begin
    while B.Len + N > B.Cap do
      if B.Cap = 0 then B.Cap := 256 else B.Cap := B.Cap * 2;
    SetLength(B.Data, B.Cap);
  end;
  Move(P^, B.Data[B.Len], N);
  Inc(B.Len, N);
end;

procedure Buf32LE(var B: TByteBuf; V: LongWord); inline;
var T: array[0..3] of Byte;
begin
  Store32LE(@T[0], V);
  BufRaw(B, @T[0], 4);
end;

function ParseDispackMem(const S: string; out Value: QWord): Boolean;
var
  i: Integer;
  Num: QWord;
  c: Char;
begin
  // parseMem de FreeArc: sufijo b/k/m/g; sin sufijo es 2^N ("24" = 16 MB)
  Result := False;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if (i > Length(S)) or not (S[i] in ['0'..'9']) then Exit;
  Num := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    if Num > (High(QWord) div 10) then Exit;
    Num := Num * 10 + Ord(S[i]) - Ord('0');
    Inc(i);
  end;
  if i <= Length(S) then c := LowerCase(S[i]) else c := '^';
  case c of
    'b': Value := Num;
    'k': Value := Num shl 10;
    'm': Value := Num shl 20;
    'g': Value := Num shl 30;
    '^': begin
           if Num > 40 then Exit;
           Value := QWord(1) shl Num;
         end;
  else
    Exit;
  end;
  Result := True;
end;

function DispackBlockSize(const Params: TStringArray): Integer;
var
  k: Integer;
  V: QWord;
begin
  Result := DISPACK_BLOCK;
  for k := 1 to High(Params) do
  begin
    if Params[k] = '' then Continue;
    if LowerCase(Params[k]) = 'x' then Continue;
    if (Length(Params[k]) > 1) and ((Params[k][1] = 'b') or (Params[k][1] = 'B')) then
    begin
      if ParseDispackMem(Copy(Params[k], 2, MaxInt), V) and (V > 0) then Result := Integer(V);
    end
    else if ParseDispackMem(Params[k], V) and (V > 0) then
      Result := Integer(V);
  end;
  if Result < 64 * 1024 then Result := 64 * 1024;
end;

function DispackEncode(Src: PByte; SrcLen: Integer; BlockSize: Integer): TBytes;
var
  Out: TByteBuf;
  Pos, P0, Len, InSize, OutLen: Integer;
  Base: LongWord;
  First: Boolean;
  Filtered: TBytes;
begin
  Result := nil;
  if BlockSize <= 0 then BlockSize := DISPACK_BLOCK;
  Out.Data := nil; Out.Len := 0; Out.Cap := 0;
  Base := 1 shl 30;
  First := True;
  Pos := 0;
  while True do
  begin
    P0 := Pos; InSize := 0; Len := 0;
    repeat
      if Pos >= SrcLen then begin Len := 0; Break; end;
      Len := SrcLen - Pos;
      if Len > DISPACK_CHUNK then Len := DISPACK_CHUNK;
      if not DetectExe(Src + Pos, Len) then Break;
      Inc(Pos, Len);
      Inc(InSize, Len);
      Len := 0;
      if InSize > BlockSize - DISPACK_CHUNK then Break;
    until False;

    if (InSize = 0) and (Len = 0) then Break;
    if First then
    begin
      Buf32LE(Out, LongWord(DISPACK_CHUNK));
      First := False;
    end;

    if InSize > 0 then
    begin
      Filtered := DisPackFilter(Src + P0, InSize, Base, OutLen);
      Buf32LE(Out, LongWord(DISPACK_TAG_EXE));
      Buf32LE(Out, LongWord(InSize));
      Buf32LE(Out, LongWord(OutLen));
      BufRaw(Out, @Filtered[0], OutLen);
    end;

    if Len > 0 then
    begin
      if (Len <> DISPACK_CHUNK) or IsTag(Load32LE(Src + Pos)) then
      begin
        Buf32LE(Out, LongWord(DISPACK_TAG_DATA));
        Buf32LE(Out, LongWord(Len));
      end;
      BufRaw(Out, Src + Pos, Len);
      Inc(Pos, Len);
    end;

    Inc(Base, LongWord(InSize + Len));
    if Base >= LongWord(3) shl 30 then Dec(Base, LongWord(2) shl 30);
  end;

  SetLength(Result, Out.Len);
  if Out.Len > 0 then Move(Out.Data[0], Result[0], Out.Len);
end;

function DispackDecode(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Integer; BlockSize: Integer): Boolean;
var
  Pos, OutPos, Chunk, Tag, Len, OutSize, InSize: Integer;
  Base: LongWord;
begin
  Result := False;
  if BlockSize <= 0 then BlockSize := DISPACK_BLOCK;
  if SrcLen < 4 then Exit;
  Chunk := Integer(Load32LE(Src));
  if (Chunk <= 0) or (Chunk > BlockSize) then Exit;
  Pos := 4; OutPos := 0; Base := 1 shl 30;
  while Pos < SrcLen do
  begin
    if SrcLen - Pos < 4 then Exit;
    Tag := Integer(Load32LE(Src + Pos));
    Inc(Pos, 4);

    if (not IsTag(LongWord(Tag))) or (LongWord(Tag) = DISPACK_TAG_DATA) then
    begin
      if LongWord(Tag) = DISPACK_TAG_DATA then
      begin
        if SrcLen - Pos < 4 then Exit;
        Len := Integer(Load32LE(Src + Pos));
        Inc(Pos, 4);
      end
      else
      begin
        // el tag es en realidad el comienzo de los datos
        Len := Chunk;
        if OutPos + Len > DstLen then Exit;
        Store32LE(Dst + OutPos, LongWord(Tag));
        if SrcLen - Pos < Len - 4 then Exit;
        Move(Src[Pos], Dst[OutPos + 4], Len - 4);
        Inc(Pos, Len - 4);
        Inc(OutPos, Len);
        Inc(Base, LongWord(Len));
        if Base >= LongWord(3) shl 30 then Dec(Base, LongWord(2) shl 30);
        Continue;
      end;
      if (Len < 0) or (Pos + Len > SrcLen) or (OutPos + Len > DstLen) then Exit;
      Move(Src[Pos], Dst[OutPos], Len);
      Inc(Pos, Len); Inc(OutPos, Len);
      Inc(Base, LongWord(Len));
    end
    else if LongWord(Tag) = DISPACK_TAG_EXE then
    begin
      if SrcLen - Pos < 8 then Exit;
      OutSize := Integer(Load32LE(Src + Pos));
      InSize := Integer(Load32LE(Src + Pos + 4));
      Inc(Pos, 8);
      if (OutSize < 0) or (InSize < 0) or
         (OutSize > BlockSize) or (InSize > BlockSize + BlockSize div 4 + 1024) then Exit;
      if (Pos + InSize > SrcLen) or (OutPos + OutSize > DstLen) then Exit;
      if not DisPackUnFilter(Src + Pos, InSize, Dst + OutPos, OutSize, Base) then Exit;
      Inc(Pos, InSize); Inc(OutPos, OutSize);
      Inc(Base, LongWord(OutSize));
    end
    else
      Exit;

    if Base >= LongWord(3) shl 30 then Dec(Base, LongWord(2) shl 30);
  end;

  Result := OutPos = DstLen;
end;

{ TDisPackStage }

constructor TDisPackStage.Create(ASource: TInStage; ABlockSize: LongWord);
var
  Cap, N: Integer;
begin
  inherited Create(ASource);
  FBlockSize := ABlockSize;
  if FBlockSize = 0 then FBlockSize := DISPACK_BLOCK;
  FBase := 1 shl 30;
  Cap := 64 * 1024;
  SetLength(FData, Cap);
  FLen := 0;
  while True do
  begin
    if FLen = Cap then
    begin
      Cap := Cap * 2;
      SetLength(FData, Cap);
    end;
    N := ASource.Read(@FData[FLen], Cap - FLen);
    if N <= 0 then Break;
    Inc(FLen, N);
  end;
  FPos := 0;
end;

function TDisPackStage.NextPiece: Boolean;
var
  Tag, Len, OutSize, InSize: Integer;
begin
  Result := False;
  if not FStarted then
  begin
    if FLen - FPos < 4 then raise EArcCorrupt.Create('dispack: missing block size');
    FChunkSize := Load32LE(@FData[FPos]);
    Inc(FPos, 4);
    if (FChunkSize = 0) or (FChunkSize > FBlockSize) then
      raise EArcCorrupt.Create('dispack: invalid block size');
    FStarted := True;
  end;
  if FPos >= FLen then Exit(False);
  if FLen - FPos < 4 then raise EArcCorrupt.Create('dispack: tag incompleto');
  Tag := Integer(Load32LE(@FData[FPos]));
  Inc(FPos, 4);

  if (not IsTag(LongWord(Tag))) or (LongWord(Tag) = DISPACK_TAG_DATA) then
  begin
    if LongWord(Tag) = DISPACK_TAG_DATA then
    begin
      if FLen - FPos < 4 then raise EArcCorrupt.Create('dispack: missing length');
      Len := Integer(Load32LE(@FData[FPos]));
      Inc(FPos, 4);
    end
    else
    begin
      Len := Integer(FChunkSize);
      if FLen - FPos < Len - 4 then raise EArcCorrupt.Create('dispack: tramo corto');
      SetLength(FOut, Len);
      Store32LE(@FOut[0], LongWord(Tag));
      Move(FData[FPos], FOut[4], Len - 4);
      Inc(FPos, Len - 4);
      Inc(FBase, LongWord(Len));
      if FBase >= LongWord(3) shl 30 then Dec(FBase, LongWord(2) shl 30);
      FOutPos := 0; FOutLen := Len;
      Exit(True);
    end;
    if (Len < 0) or (FPos + Len > FLen) then raise EArcCorrupt.Create('dispack: tramo corto');
    SetLength(FOut, Len);
    if Len > 0 then Move(FData[FPos], FOut[0], Len);
    Inc(FPos, Len);
    Inc(FBase, LongWord(Len));
  end
  else if LongWord(Tag) = DISPACK_TAG_EXE then
  begin
    if FLen - FPos < 8 then raise EArcCorrupt.Create('dispack: cabecera corta');
    OutSize := Integer(Load32LE(@FData[FPos]));
    InSize := Integer(Load32LE(@FData[FPos + 4]));
    Inc(FPos, 8);
    if (OutSize < 0) or (InSize < 0) or
       (OutSize > Integer(FBlockSize)) or
       (InSize > Integer(FBlockSize + FBlockSize div 4 + 1024)) then
      raise EArcCorrupt.Create('dispack: invalid size');
    if FPos + InSize > FLen then raise EArcCorrupt.Create('dispack: tramo corto');
    SetLength(FOut, OutSize);
    if not DisPackUnFilter(@FData[FPos], InSize, @FOut[0], OutSize, FBase) then
      raise EArcCorrupt.Create('dispack: could not unfilter');
    Inc(FPos, InSize);
    Inc(FBase, LongWord(OutSize));
  end
  else
    raise EArcCorrupt.Create('dispack: tag desconocido');

  if FBase >= LongWord(3) shl 30 then Dec(FBase, LongWord(2) shl 30);
  FOutPos := 0; FOutLen := Length(FOut);
  Result := True;
end;

function TDisPackStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  N: SizeInt;
begin
  while FOutPos >= FOutLen do
    if not NextPiece then Exit(0);
  N := FOutLen - FOutPos;
  if N > Count then N := Count;
  Move(FOut[FOutPos], Buf^, N);
  Inc(FOutPos, N);
  Result := N;
end;

end.
