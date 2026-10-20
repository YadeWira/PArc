unit parc_canon;
{ ================================================================================
  LimitAndCanonize — port de la canonización de métodos de FreeArc 0.67.1.

  Por cada etapa del método de un bloque de datos hace lo que hace FreeArc:
    1. limitDictionary (ArcvProcessRead.hs:120):
         mem = roundMemUp(totalBytes + totalBytes div 100 + 512);
         por etapa, si GetDictionary() > mem -> SetDictionary(mem) (Compression.h:419).
       4x4 propaga el límite al compresor interno (C_4x4.h:35).
    2. Canonización: ShowCompressionMethod(buf, purify=TRUE) de cada clase
       (CompressionLibrary.cpp:644) — el string que queda almacenado.

  Portado de Compression/*/C_*.cpp y C_*.h; el oráculo es la salida real de
  arc.exe 0.67.1 (lb-f*.txt del corpus compat). Etapas sin diccionario
  (exe/delta/mm/tta/ppmd/storing) solo se canonizan.             — PA-Lab
  ================================================================================ }
{$mode objfpc}{$H+}
interface

function LimitAndCanonize(const Method: string; BlockSize: Int64): string;

implementation

uses SysUtils, Math, parc_methods;

const
  KB = 1024; MB = 1024*1024; GB = Int64(1024)*1024*1024;
  INT_MAX = High(Integer);
  GRZ_MaxBlockSize = 64*MB;   { C_GRZip; no alcanza a capar en el corpus }
  default_Tornado_method = 5; { Tornado.cpp:77 }

{ --- showMem (Compression.hs:547-556) -------------------------------------- }

function ShowMem(Mem: Int64): string;
  function Fmt(Val, NextVal: Int64; const Str: string): string;
  begin
    if (Mem mod Val = 0) or (NextVal > 0) and (Mem div NextVal >= 4096) then
      Result := IntToStr((Mem + Val div 2) div Val) + Str
    else
      Result := Fmt(KB, 0, 'kb');
  end;
begin
  if Mem = 0 then Exit('0b');
  if (Mem mod GB = 0) or (Mem div MB >= 4096) then Exit(Fmt(GB, 0, 'gb'));
  if (Mem mod MB = 0) or (Mem div KB >= 4096) then Exit(Fmt(MB, 0, 'mb'));
  Result := Fmt(KB, 0, 'kb');
end;

{ --- roundMemUp (Compression.hs:559-560) ------------------------------------ }

function RoundMemUp(Mem: Int64): Int64;
begin
  if Mem >= 4096*KB then Result := ((Mem + MB - 1) div MB) * MB
                    else Result := ((Mem + KB - 1) div KB) * KB;
end;

function LB(X: Int64): Integer;   { floor(log2(X)), X>0 }
begin
  Result := 0;
  while (X shr (Result+1)) > 0 do Inc(Result);
end;

function RoundUpPow2(X: Int64): Int64;   { roundup_to_power_of(x,2) }
begin
  Result := 1;
  while Result < X do Result := Result shl 1;
end;

{ --- parseMem de FreeArc: sufijos b/kb/mb/gb; pelado = bytes ---------------- }

function ParseMem(const S: string; Def: Int64): Int64;
var T: string; Mult: Int64; N: Integer;
begin
  Result := Def; T := LowerCase(Trim(S)); if T = '' then Exit;
  N := 0; Mult := 1;
  if Copy(T, Length(T)-1, 2) = 'gb' then begin Mult := GB; N := 2 end
  else if Copy(T, Length(T)-1, 2) = 'mb' then begin Mult := MB; N := 2 end
  else if Copy(T, Length(T)-1, 2) = 'kb' then begin Mult := KB; N := 2 end
  else if T[Length(T)] = 'b' then N := 1
  else if T[Length(T)] = 'k' then begin Mult := KB; N := 1 end
  else if T[Length(T)] = 'm' then begin Mult := MB; N := 1 end
  else if T[Length(T)] = 'g' then begin Mult := GB; N := 1 end;
  Result := StrToInt64Def(Copy(T, 1, Length(T)-N), -1) * Mult;
  if Result < 0 then Result := Def;
end;

{ parseMem del C (Common.cpp): sin sufijo es 2^N. }
function CMem(const S: string; Def: Int64): Int64;
var
  q: QWord;
begin
  if parc_methods.ParseMem(S, q) then Result := q else Result := Def;
end;

{ showMem del C (Common.cpp:255): la unidad más grande que divide exacto. }
function CShowMem(Mem: Int64): string;
begin
  if Mem = 0 then Result := '0b'
  else if Mem mod GB = 0 then Result := IntToStr(Mem div GB) + 'gb'
  else if Mem mod MB = 0 then Result := IntToStr(Mem div MB) + 'mb'
  else if Mem mod KB = 0 then Result := IntToStr(Mem div KB) + 'kb'
  else Result := IntToStr(Mem) + 'b';
end;

function IsMem(const S: string): Boolean;
begin
  Result := (S <> '') and (S[1] in ['0'..'9']);
end;

function Num(const S: string; Def: Int64): Int64;
begin
  Result := StrToInt64Def(S, Def);
end;

const
  StdEnc:  array[0..16] of Integer = (0,1,2,3,3,4,4,4,4,4,4,4,4,4,4,4,4);
  StdHS:   array[0..16] of Int64   = (0,16*KB,64*KB,128*KB,2*MB,8*MB,32*MB,128*MB,512*MB,2*GB,2*GB,
                                       256*MB,256*MB,384*MB,512*MB,512*MB,128*MB);
  StdBuf:  array[0..16] of Int64   = (1*MB,1*MB,2*MB,4*MB,8*MB,16*MB,64*MB,256*MB,1*GB,1*GB,1*GB,
                                       128*MB,128*MB,128*MB,128*MB,128*MB,128*MB);

{ ================================================================================ }
{ Canoniza una cadena de etapas con un límite de diccionario ya calculado          }

function CanonChain(const Method: string; Limit: Int64): string;
var
  Stages: TStringArray;
  I: Integer;

  function CanonStage(const S: string): string;
  var
    Parts: TStringArray;
    Name, P: string;
    J: Integer;
    BS, MC, MML, Bar, Sm, HSL, Amp, Hash, Alg, MFi, NFB, PB, LC, LP, HS: Int64;
    MFSet: Boolean;
    M, MR, W, MM, MS, Num9, Enc, Order, Mem, Chunk, Got, Lvl, BPos: Int64;
    StartI: Integer;
    L: string;
    LZP, A, C3, Ext: Boolean;
    Interno: string;
    I: Integer;

    function Pr(N: Integer): string;
    begin
      if N < Length(Parts) then Result := Parts[N] else Result := '';
    end;

begin

    Parts := S.Split([':']);
    Name  := LowerCase(Parts[0]);
    P     := '';

    { --- rep (C_REP.cpp/.h). Defaults: 64mb, mc100, c0, mml512, dINTMAX,
          s512, h0, a1. N% -> MinCompression; N -> MinMatchLen. :c se purifica. }
    if Name = 'rep' then
    begin
      BS := ParseMem(Pr(0), 64*MB);
      if BS > Limit then BS := Limit;                 { SetDictionary }
      MC := 100; MML := 512; Bar := INT_MAX;
      Sm := 512; HSL := 0;   Amp := 1;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) and (Copy(L, Length(L), 1) = '%') then MC := Num(Copy(L, 1, Length(L)-1), 100)
        else if (L <> '') and (L[1] in ['0'..'9']) then MML := Num(L, 512)
        else if Copy(L,1,1) = 'd' then Bar := ParseMem(Copy(L,2,MaxInt), INT_MAX)
        else if Copy(L,1,1) = 's' then Sm := Num(Copy(L,2,MaxInt), 512)
        else if Copy(L,1,1) = 'h' then HSL := Num(Copy(L,2,MaxInt), 0)
        else if Copy(L,1,1) = 'a' then Amp := Num(Copy(L,2,MaxInt), 1);
        { :c<ChunkSize> se ignora: purify }
      end;
      Result := 'rep:' + ShowMem(BS);
      if MC <> 100 then Result := Result + (':' + IntToStr(MC) + '%');
      if MML <> 512 then Result := Result + (':' + IntToStr(MML));
      if Bar <> INT_MAX then Result := Result + (':d' + ShowMem(Bar));
      if Sm <> 512 then Result := Result + (':s' + IntToStr(Sm));
      if HSL <> 0 then Result := Result + (':h' + IntToStr(HSL));
      if Amp <> 1 then Result := Result + (':a' + IntToStr(Amp));
      Exit;
    end;

    { --- lzma (C_LZMA.cpp/.h). Defaults: 64mb, h0, alg1, nfb32, mfHT4,
          mc0, pb2, lc3, lp0. SetDictionary: dict=max(32kb, mem) en 32-bit. }
    if Name = 'lzma' then
    begin
      BS := ParseMem(Pr(0), 64*MB);
      if BS > Limit then BS := Limit;
      if BS < 32*KB then BS := 32*KB;
      Hash := Int64(0); Alg := 1; MFi := 0;  { 0=HT4 1=BT2 2=BT3 3=BT4 4=HC4 }
      MFSet := False;
      NFB := Int64(32); MC := 0; PB := 2; LC := 3; LP := 0;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) then NFB := Num(L, 32)
        else if Copy(L,1,1) = 'h' then Hash := ParseMem(Copy(L,2,MaxInt), 0)
        { C_LZMA.cpp:623-627: los presets fijan algoritmo, fast bytes y ciclos, y el match
          finder solo si todavía no se dio uno ("max" = normal + bt4 + 128) }
        else if L = 'fastest' then begin Alg := 0; if not MFSet then MFi := 0; MFSet := True; NFB := 5; MC := 1; end
        else if L = 'fast' then begin Alg := 0; if not MFSet then MFi := 0; MFSet := True; NFB := 32; MC := 0; end
        else if L = 'normal' then begin Alg := 1; if not MFSet then MFi := 0; MFSet := True; NFB := 32; MC := 0; end
        else if L = 'max' then begin Alg := 1; if not MFSet then MFi := 3; MFSet := True; NFB := 128; MC := 0; end
        else if L = 'ultra' then begin Alg := 1; if not MFSet then MFi := 3; MFSet := True; NFB := 128; MC := 128; end
        else if (Copy(L,1,1) = 'a') and (Length(L) = 2) then Alg := Num(Copy(L,2,1), 1)
        else if L = 'bt2' then begin MFi := 1; MFSet := True; end
        else if L = 'bt3' then begin MFi := 2; MFSet := True; end
        else if L = 'bt4' then begin MFi := 3; MFSet := True; end
        else if L = 'hc4' then begin MFi := 4; MFSet := True; end
        else if L = 'ht4' then begin MFi := 0; MFSet := True; end
        else if Copy(L,1,2) = 'mc' then MC := Num(Copy(L,3,MaxInt), 0)
        else if Copy(L,1,2) = 'pb' then PB := Num(Copy(L,3,MaxInt), 2)
        else if Copy(L,1,2) = 'lc' then LC := Num(Copy(L,3,MaxInt), 3)
        else if Copy(L,1,2) = 'lp' then LP := Num(Copy(L,3,MaxInt), 0);
      end;
      Result := 'lzma:' + ShowMem(BS);
      if Hash <> 0 then Result := Result + (':h' + ShowMem(Hash));
      if MFi = 0 then
      begin
        if Alg = 2 then Result := Result + ':a2'
        else if Alg = 0 then Result := Result + ':fast'
        else Result := Result + ':normal';
      end
      else
      begin
        if Alg = 0 then Result := Result + ':fast' else if Alg = 1 then Result := Result + ':normal' else Result := Result + ':max';
        case MFi of 1: Result := Result + ':bt2'; 2: Result := Result + ':bt3'; 3: Result := Result + ':bt4'; 4: Result := Result + ':hc4'; end;
      end;
      Result := Result + (':' + IntToStr(NFB));
      if MC <> 0 then Result := Result + (':mc' + IntToStr(MC));
      if PB <> 2 then Result := Result + (':pb' + IntToStr(PB));
      if LC <> 3 then Result := Result + (':lc' + IntToStr(LC));
      if LP <> 0 then Result := Result + (':lp' + IntToStr(LP));
      Exit;
    end;

    { --- grzip (C_GRZip.cpp/.h). Defaults: m1, 8mb, lzp on, mm32, h15.
          SetBlockSize: BS=min(bs,GRZ_Max); h=min(h, 1+lb(BS-1)).
          Show imprime l<h> SIEMPRE que EnableLZP. }
    if Name = 'grzip' then
    begin
      BS := Int64(0); M := 1; MML := 32; HSL := 15;
      LZP := True; A := False;
      for J := 0 to High(Parts) do
      begin
        if J = 0 then Continue;
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) and (BS = 0) then BS := ParseMem(L, 0)
        else if (Copy(L,1,1) = 'm') and (Length(L) >= 2) and (L[2] in ['0'..'9']) then M := Num(Copy(L,2,MaxInt), 1)
        else if L = 'l' then LZP := False
        else if Copy(L,1,1) = 'l' then MML := Num(Copy(L,2,MaxInt), 32)
        else if Copy(L,1,1) = 'h' then HSL := Num(Copy(L,2,MaxInt), 15)
        else if L = 'a' then A := True
        else if BS = 0 then BS := ParseMem(L, 0);
      end;
      if BS = 0 then BS := 8*MB;
      if BS > Limit then BS := Limit;
      if BS > GRZ_MaxBlockSize then BS := GRZ_MaxBlockSize;
      if HSL > 1 + LB(BS-1) then HSL := 1 + LB(BS-1);
      Result := 'grzip:' + ShowMem(BS) + ':m' + IntToStr(M) + ':';
      if LZP then Result := Result + ('l' + IntToStr(MML) + ':h' + IntToStr(HSL))
             else Result := Result + 'l';
      if A then Result := Result + (':a');
      Exit;
    end;

    { --- dict (C_Dict.cpp/.h). Defaults: 64mb, mc100, c20, l2048, m100, s50, r4.
          Presets: p -> l8192 m400 s100; f -> l2048 m100 s50 r0. }
    if Name = 'dict' then
    begin
      BS := ParseMem(Pr(0), 64*MB);
      if BS > Limit then BS := Limit;
      MC := 100; W := 20; LC := 2048; MM := 100; MS := 50; MR := 4;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if L = 'p' then begin LC := 8192; MM := 400; MS := 100; MR := 4 end
        else if L = 'f' then begin LC := 2048; MM := 100; MS := 50; MR := 0 end
        else if (L <> '') and (L[1] in ['0'..'9']) then
          if Copy(L, Length(L), 1) = '%' then MC := Num(Copy(L, 1, Length(L)-1), 100)
          else BS := ParseMem(L, 64*MB)
        else if Copy(L,1,1) = 'c' then W := Num(Copy(L,2,MaxInt), 20)
        else if Copy(L,1,1) = 'l' then LC := Num(Copy(L,2,MaxInt), 2048)
        else if Copy(L,1,1) = 'm' then MM := Num(Copy(L,2,MaxInt), 100)
        else if Copy(L,1,1) = 's' then MS := Num(Copy(L,2,MaxInt), 50)
        else if Copy(L,1,1) = 'r' then MR := Num(Copy(L,2,MaxInt), 4);
      end;
      if BS > Limit then BS := Limit;
      Result := 'dict:' + ShowMem(BS);
      if MC <> 100 then Result := Result + (':' + IntToStr(MC) + '%');
      if W <> 20 then Result := Result + (':c' + IntToStr(W));
      if LC <> 2048 then Result := Result + (':l' + IntToStr(LC));
      if MM <> 100 then Result := Result + (':m' + IntToStr(MM));
      if MS <> 50 then Result := Result + (':s' + IntToStr(MS));
      if MR <> 4 then Result := Result + (':r' + IntToStr(MR));
      Exit;
    end;

    { --- lzp (C_LZP.cpp/.h). Defaults: 8mb, mc100, mm64, h18, dINTMAX, s32.
          Show imprime :<mm>:h<h> SIEMPRE. SetBlockSize: h=min(h,1+lb(BS-1)). }
    if Name = 'lzp' then
    begin
      BS := ParseMem(Pr(0), 8*MB);
      if BS > Limit then BS := Limit;
      MC := 100; MML := 64; HSL := 18; Bar := INT_MAX; Sm := 32;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) then
          if Copy(L, Length(L), 1) = '%' then MC := Num(Copy(L, 1, Length(L)-1), 100)
          else MML := Num(L, 64)
        else if Copy(L,1,1) = 'h' then HSL := Num(Copy(L,2,MaxInt), 18)
        else if Copy(L,1,1) = 'd' then Bar := ParseMem(Copy(L,2,MaxInt), INT_MAX)
        else if Copy(L,1,1) = 's' then Sm := Num(Copy(L,2,MaxInt), 32);
      end;
      if HSL > 1 + LB(BS-1) then HSL := 1 + LB(BS-1);
      Result := 'lzp:' + ShowMem(BS);
      if MC <> 100 then Result := Result + (':' + IntToStr(MC) + '%');
      Result := Result + (':' + IntToStr(MML) + ':h' + IntToStr(HSL));
      if Bar <> INT_MAX then Result := Result + (':d' + ShowMem(Bar));
      if Sm <> 32 then Result := Result + (':s' + IntToStr(Sm));
      Exit;
    end;

    { --- tornado (C_Tornado.cpp). Defaults = std_Tornado_method[5]; el número
          se imprime sólo si <> de default_Tornado_method (5).
          SetDictionary: si mem < buffer, hashsize = 4*min(hs/4, roundup2(mem)). }
    if Name = 'tor' then
    begin
      Num9 := 5; BS := StdBuf[5]; HS := StdHS[5]; Enc := 4;
      C3 := False;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if (L <> '') and (L[1] in ['0'..'9']) then
          if Num(L, -1) = StrToInt64Def(L, -2) then
          begin Num9 := Num(L, 5); BS := StdBuf[Num9]; HS := StdHS[Num9]; Enc := StdEnc[Num9]; end
          else BS := ParseMem(L, BS)
        else if Copy(L,1,1) = 'c' then begin Enc := Num(Copy(L,2,MaxInt), Enc); C3 := True end
        else if Copy(L,1,1) = 'h' then HS := ParseMem(Copy(L,2,MaxInt), HS)
        else if BS = StdBuf[Num9] then BS := ParseMem(L, BS);
      end;
      if Num9 > High(StdBuf) then Num9 := High(StdBuf);
      if BS = 0 then BS := StdBuf[Num9];
      if HS = 0 then HS := StdHS[Num9];
      if (BS > Limit) then
      begin
        if Limit < BS then
          HS := 4 * Min(Int64(HS div 4), RoundUpPow2(Limit));  { PtrVal=4, 32-bit }
        BS := Limit;
      end;
      Result := 'tor';
      if Num9 <> default_Tornado_method then Result := Result + (':' + IntToStr(Num9));
      Result := Result + (':' + ShowMem(BS));
      if HS <> StdHS[Num9] then Result := Result + (':h' + ShowMem(HS));
      if C3 and (Enc <> StdEnc[Num9]) then Result := Result + (':c' + IntToStr(Enc));
      Exit;
    end;

    { --- dispack (C_DisPack.cpp): BlockSize por defecto 8 MB; :x no cambia el flujo. }
    if (Name = 'dispack') or (Name = 'dispack070') then
    begin
      BS := 8*MB;
      Ext := False;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if L = 'x' then
        begin
          Ext := True;
          Continue;
        end;
        if (L <> '') and (L[1] = 'b') and (Length(L) > 1) then
          BS := CMem(Copy(L, 2, MaxInt), BS)
        else if L <> '' then
          BS := CMem(L, BS);
      end;
      if BS <= 0 then BS := 8*MB;
      Result := 'dispack070';
      if BS <> 8*MB then Result := Result + (':' + ShowMem(BS));   // Show no pone la 'b'
      if Ext then Result := Result + (':x');
      Exit;
    end;

    { --- ppmd (C_PPMD.cpp): defaults order10, 48mb, mr0, c0. Sin límite. }
    if Name = 'ppmd' then
    begin
      Order := 10; Mem := 48*MB; MR := 0; Chunk := Int64(0);
      Got := 0;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if L = 'r' then MR := 1
        else if L = 'r2' then MR := 2
        else if Copy(L,1,1) = 'c' then Chunk := ParseMem(Copy(L,2,MaxInt), 0)
        else if Got = 0 then begin Order := Num(L, 10); Got := 1 end
        else Mem := ParseMem(L, 48*MB);
      end;
      Result := 'ppmd:' + IntToStr(Order) + ':' + ShowMem(Mem);
      if MR = 1 then Result := Result + ':r' else if MR = 2 then Result := Result + ':r2';
      if Chunk <> 0 then Result := Result + (':c' + ShowMem(Chunk));
      Exit;
    end;

    { --- tta (C_TTA.cpp): defaults level3, s0. }
    if Name = 'tta' then
    begin
      Lvl := 3;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if Copy(L,1,1) = 'm' then Lvl := Num(Copy(L,2,MaxInt), 3);
      end;
      Result := 'tta';
      if Lvl <> 3 then Result := Result + (':m' + IntToStr(Lvl));
      Exit;
    end;

    { --- lz4 (C_LZ4.cpp/.h). Defaults: c0, b1mb, h0, 100%. Sin SetDictionary propio, así
          que el límite no lo toca; "hc" es c2. showMem del C: unidad exacta. }
    if Name = 'lz4' then
    begin
      MC := 0; BS := MB; HS := 0; M := 100;
      for J := 1 to High(Parts) do
      begin
        L := LowerCase(Parts[J]);
        if L = '' then Continue;
        if L = 'hc' then MC := 2
        else if L[1] = 'c' then MC := Num(Copy(L,2,MaxInt), 0)
        else if L[1] = 'b' then BS := CMem(Copy(L,2,MaxInt), MB)
        else if L[1] = 'h' then HS := CMem(Copy(L,2,MaxInt), 0)
        else if L[Length(L)] = '%' then M := Num(Copy(L,1,Length(L)-1), 100);
      end;
      Result := 'lz4';
      if MC <> 0 then Result := Result + ':c' + IntToStr(MC);
      if BS <> MB then Result := Result + ':b' + CShowMem(BS);
      if HS <> 0 then Result := Result + ':h' + CShowMem(HS);
      if M <> 100 then Result := Result + ':' + IntToStr(M) + '%';
      Exit;
    end;

    { --- 4x4 (C_4x4.cpp/.h): :b<mem> propio (no se limita ni purifica),
          el resto es el método interno, que hereda el límite y se canoniza.
          Igual que parse_4x4: un parámetro es propio si empieza con dígito o si el
          segundo carácter es dígito (t4, i2, r99, b7mb); el primero que no, arranca el
          método interno. Sin método interno, el default del constructor: tor:3:1mb. }
    if Name = '4x4' then
    begin
      BS := 0; StartI := 0;
      for J := 1 to High(Parts) do
      begin
        L := Parts[J];
        if (L <> '') and ((L[1] in ['0'..'9']) or
                          ((Length(L) > 1) and (L[2] in ['0'..'9']))) then
        begin
          // Parámetros propios de 4x4: :b<mem>, :t<n>, :i<n>, :r<porcentaje>, un número
          // suelto (hilos) o una memoria suelta (8mb). Sólo :b queda en el texto canónico
          // (purify no imprime los que sólo afectan a comprimir).
          if L[1] in ['0'..'9'] then
          begin
            if StrToInt64Def(L, -1) < 0 then BS := ParseMem(L, 0);   // "8mb" = BlockSize
          end
          else if (L[1] = 'b') or (L[1] = 'B') then BS := ParseMem(Copy(L, 2, MaxInt), 0);
        end
        else
        begin StartI := J; Break; end;
      end;
      if StartI = 0 then Interno := 'tor:3:1mb'
      else
      begin
        Interno := '';
        for J := StartI to High(Parts) do
        begin
          if Interno <> '' then Interno := Interno + (':');
          Interno := Interno + (Parts[J]);
        end;
      end;
      Result := '4x4';
      // ShowCompressionMethod con purify=True no imprime t/i/r (solo afectan a comprimir):
      // quedan el :b propio y el método interno.
      if BS <> 0 then Result := Result + (':b' + ShowMem(BS));
      Result := Result + (':' + CanonChain(Interno, Limit));
      Exit;
    end;

    { --- etapas sin diccionario ni parámetros en el corpus }
    if (Name = 'exe') or (Name = 'mm') or (Name = 'delta') or (Name = 'storing')
       or (Name = 'crc') then Exit(Name);

    Result := S;   { desconocida: igual (criterio "lo que no se toca, igual") }
  end;

begin
  Stages := Method.Split(['+'], TStringSplitOptions.None);
  SetLength(Stages, Length(Stages));
  Result := '';
  for I := 0 to High(Stages) do
  begin
    if I > 0 then Result := Result + ('+');
    Result := Result + (CanonStage(Stages[I]));
  end;
end;

{ --- API pública ------------------------------------------------------------ }

function LimitAndCanonize(const Method: string; BlockSize: Int64): string;
begin
  Result := CanonChain(Method, RoundMemUp(BlockSize + BlockSize div 100 + 512));
end;

end.
