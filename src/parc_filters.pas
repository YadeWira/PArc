{ Filtro exe (lado decodificador): BCJ x86 del LZMA SDK 26.03 (Bra86.c, Igor Pavlov, dominio
  público). El stream es el de los filtros x86 de 7-Zip/xz: los datos convertidos tal cual, sin
  cabecera; la posición (ip) y el estado siguen de un buffer al otro, y los últimos bytes que no
  alcanzan para una instrucción quedan sin convertir. (delta está en parc_delta.) }
unit parc_filters;

{$mode objfpc}{$H+}
{$goto on}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

type
  TBcjX86Stage = class(TInStage)
  private
    FBuf: array of Byte;
    FLen: SizeInt;        // bytes válidos en FBuf
    FOut: SizeInt;        // bytes ya convertidos (listos para entregar) al principio de FBuf
    FOutPos: SizeInt;     // cuántos de esos ya se entregaron
    FIp, FState: LongWord;
    FEof: Boolean;
    procedure Fill;
  public
    constructor Create(ASource: TInStage);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Núcleo BCJ x86. Devuelve cuántos bytes quedaron procesados. }
function BcjX86Code(Data: PByte; Size: SizeInt; Pc: LongWord; var State: LongWord; Encoding: Boolean): SizeInt;
function BcjX86Decode(Data: PByte; Size: SizeInt; Pc: LongWord; var State: LongWord): SizeInt;

implementation

uses
  parc_bytes;

function GetUi32(p: PByte): LongWord; inline;
begin
  Result := LongWord(p[0]) or (LongWord(p[1]) shl 8) or (LongWord(p[2]) shl 16) or (LongWord(p[3]) shl 24);
end;

procedure SetUi32(p: PByte; v: LongWord); inline;
begin
  p[0] := Byte(v); p[1] := Byte(v shr 8); p[2] := Byte(v shr 16); p[3] := Byte(v shr 24);
end;

{ BR86_NEED_CONV_FOR_MS_BYTE: el byte alto es 0x00 o 0xFF }
function NeedConv(b: LongWord): Boolean; inline;
begin
  Result := ((b + 1) and $FE) = 0;
end;

{ Traducción directa de Z7_BRANCH_CONV_ST(X86), conservando su estructura de saltos para poder
  compararla línea a línea con el original. c = dirección de la instrucción siguiente =
  Pc + (offset del operando) + 4. BR_CONVERT_VAL: al codificar se suma c, al decodificar se resta. }
function BcjX86Code(Data: PByte; Size: SizeInt; Pc: LongWord; var State: LongWord; Encoding: Boolean): SizeInt;
label
  cont, start, m0, m1, m2, main_loop, a0, a1, a2, a3, fin_p, fin;
var
  p, lim: PByte;
  mask, v, c: LongWord;
begin
  if Size < 5 then Exit(0);
  p := Data;
  lim := Data + Size - 4;
  mask := State;
  Pc := Pc + 4;
  goto start;

cont:
  mask := mask or 4;
start:
  if p >= lim then goto fin;
  v := GetUi32(p) xor $E8E8E8E8;
  Inc(p, 4);
  if (v and $FE) = 0 then goto m0;
  mask := mask shr 1;
  if (v and $FE00) = 0 then goto m1;
  mask := mask shr 1;
  if (v and $FE0000) = 0 then goto m2;
  mask := 0;
  if (v and $FE000000) = 0 then goto a3;
  goto main_loop;

m0: Dec(p);
m1: Dec(p);
m2: Dec(p);
  if mask = 0 then goto a3;
  if p > lim then goto fin_p;
  if (mask > 4) or (mask = 3) then
  begin
    mask := mask shr 1;
    goto cont;
  end;
  mask := mask shr 1;
  if NeedConv(p[mask]) then goto cont;
  v := GetUi32(p);
  v := v + (1 shl 24);
  if (v and $FE000000) <> 0 then goto cont;
  c := Pc + LongWord(p - Data);
  if Encoding then v := v + c else v := v - c;
  mask := mask shl 3;
  if NeedConv(v shr mask) then
  begin
    v := v xor ((LongWord($100) shl mask) - 1);
    if Encoding then v := v + c else v := v - c;
  end;
  mask := 0;
  v := v and ((1 shl 25) - 1);
  v := v - (1 shl 24);
  SetUi32(p, v);
  Inc(p, 4);
  goto main_loop;

main_loop:
  if p >= lim then goto fin;
  while True do
  begin
    v := GetUi32(p) xor $E8E8E8E8;
    Inc(p, 4);
    if (v and $FE) = 0 then goto a0;
    if (v and $FE00) = 0 then goto a1;
    if (v and $FE0000) = 0 then goto a2;
    if (v and $FE000000) = 0 then goto a3;
    if p >= lim then goto fin;
  end;

a0: Dec(p);
a1: Dec(p);
a2: Dec(p);
a3:
  if p > lim then goto fin_p;
  v := GetUi32(p);
  v := v + (1 shl 24);
  if (v and $FE000000) <> 0 then goto cont;
  c := Pc + LongWord(p - Data);
  if Encoding then v := v + c else v := v - c;
  v := v and ((1 shl 25) - 1);
  v := v - (1 shl 24);
  SetUi32(p, v);
  Inc(p, 4);
  goto main_loop;

fin_p:
  Dec(p);
fin:
  State := mask;
  Result := p - Data;
end;

function BcjX86Decode(Data: PByte; Size: SizeInt; Pc: LongWord; var State: LongWord): SizeInt;
begin
  Result := BcjX86Code(Data, Size, Pc, State, False);
end;

{ TBcjX86Stage }

const
  BCJ_BUFFER_SIZE = 1 shl 20;

constructor TBcjX86Stage.Create(ASource: TInStage);
begin
  inherited Create(ASource);
  SetLength(FBuf, BCJ_BUFFER_SIZE);
end;

{ Se convierte lo que haya en el buffer; lo que el filtro no llegó a procesar (el final, que
  podría ser el inicio de una instrucción) se guarda y se completa con la próxima lectura. Un
  tramo de 5 bytes o menos (menos que una instrucción E8/E9 entera) sale sin convertir. }
procedure TBcjX86Stage.Fill;
var
  n, Rem: SizeInt;
begin
  Rem := FLen - FOut;
  if Rem > 0 then Move(FBuf[FOut], FBuf[0], Rem);
  FLen := Rem;
  FOut := 0;
  FOutPos := 0;
  // Llenar el buffer entero (o hasta el final). No alcanza con una sola lectura: si la fuente
  // devuelve un pedazo chico, un tramo de <=5 bytes a mitad de stream saldría sin convertir,
  // y el compresor solo dejaba sin convertir el final del stream
  while not FEof and (FLen < Length(FBuf)) do
  begin
    n := Source.Read(@FBuf[FLen], Length(FBuf) - FLen);
    if n = 0 then FEof := True;
    Inc(FLen, n);
  end;
  if FLen = 0 then Exit;
  if FLen <= 5 then
    FOut := FLen
  else
  begin
    FOut := BcjX86Decode(@FBuf[0], FLen, FIp, FState);
    if FEof and (FOut = 0) then FOut := FLen;   // nunca se trabe al final
  end;
  Inc(FIp, LongWord(FOut));
end;

function TBcjX86Stage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  while FOutPos >= FOut do
  begin
    if FEof and (FLen - FOut = 0) then Exit(0);
    Fill;
  end;
  Result := FOut - FOutPos;
  if Result > Count then Result := Count;
  Move(FBuf[FOutPos], Buf^, Result);
  Inc(FOutPos, Result);
end;

end.
