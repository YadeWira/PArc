{ Selección de archivos de la línea de comandos (opciones al estilo de FreeArc 0.67, Options.hs;
  implementación propia): listas @archivo, -n/-x, -sm/-sl, -ta/-tb/-tn/-to, -ap, --dirs/-ed,
  y lo que se parsea con ellas (tamaños, fechas, períodos, -ag, -kf).

  Reglas (las mismas al agregar y al leer: l, t, x, e, d):
  - un nombre entra si coincide con algún patrón (si se dio alguno), con algún -n (si se dio -n;
    un -n@lista vacía no deja pasar nada), con ninguna -x, y si cumple los filtros de tamaño y
    de fecha (que solo miran archivos y enlaces);
  - los directorios entran salvo -ed, o salvo que haya un filtro de contenido (-n, -sm, -sl,
    -ta, -tb, -tn, -to) y no se haya dado --dirs: así un filtro no deja directorios vacíos de
    lo que no pasó;
  - -ap<dir>: al leer solo cuenta lo que está debajo de <dir>/ (sin <dir> mismo), y los
    nombres se comparan sin ese prefijo. }
unit parc_select;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, parc_os, parc_archive;

type
  TDirsMode = (dmAuto, dmAlways, dmNever);
  TBoolArray = array of Boolean;

  TSelectOptions = record
    Patterns: TStrings;      // nombres/máscaras posicionales (nil = todos); al agregar no se usan
    Includes: TStrings;      // -n
    IncludeGiven: Boolean;   //   se dio -n (aunque la lista quede vacía)
    Excludes: TStrings;      // -x
    SizeMore, SizeLess: Int64;          // -sm/-sl; -1 = sin filtro
    HasAfter, HasBefore: Boolean;
    TimeAfter, TimeBefore: Int64;       // ns UTC: mtime >= After, mtime < Before
    Dirs: TDirsMode;         // --dirs / -ed
    ArcPath: string;         // -ap, saneado ('' = sin)
  end;

{ Opciones vacías (todo pasa). }
function DefaultSelect: TSelectOptions;
{ ¿Hay algún filtro de contenido (-n, tamaño, fecha)? }
function ContentFilters(const S: TSelectOptions): Boolean;
{ ¿Entra un nombre (ya relativo a -ap) con esos datos? }
function Selected(const S: TSelectOptions; const Name: string; IsDir: Boolean; Size, MTimeNs: Int64;
  UsePatterns: Boolean = True): Boolean;
{ Name está debajo de -ap: Rel es lo que queda. Sin -ap, True y Rel = Name. }
function UnderArcPath(const S: TSelectOptions; const Name: string; out Rel: string): Boolean;
{ Selección sobre un archivo abierto: un elemento por A.Files. }
function SelectArchive(A: TArchive; const S: TSelectOptions): TBoolArray;

{ Tamaño: dígitos con sufijo opcional b, k, m, g (kb, mb, gb; potencias de 1024); sin sufijo,
  DefMult. }
function ParseSizeArg(const Text: string; DefMult: Int64; out V: Int64): Boolean;
{ -lc/-ld: un tamaño (sin sufijo = MB) o N% de la memoria física. }
function ParseMemLimit(const Text: string; out V: Int64): Boolean;
{ YYYYMMDD[hh[mm[ss]]] en hora local (se ignoran los separadores no numéricos) -> ns UTC. }
function ParseAbsTime(const Text: string; out Ns: Int64): Boolean;
{ Período [<n>w][<n>d][<n>h][<n>m][<n>s] (un número solo = días) -> ns. }
function ParsePeriod(const Text: string; out Ns: Int64): Boolean;
{ Ahora, en ns UTC. }
function NowNs: Int64;

{ Agrega a Dst las líneas de un archivo de lista: UTF-8 (con o sin BOM), una por línea, sin
  las vacías ni las que empiezan con '#'. Lanza EFOpenError si no se puede leer. }
procedure ReadListFile(const FileName: string; Dst: TStrings);
{ Item o, si empieza con '@', el contenido de esa lista. }
procedure AddItemOrList(const Item: string; Dst: TStrings);

{ -ag[FMT]: Name con la fecha y hora local agregadas al nombre base (antes de la extensión).
  FMT: corridas de Y (YY = 2 dígitos, si no 4), M, D, h, m, s (2 dígitos); lo demás, literal.
  Vacío = YYYYMMDDhhmmss. }
function AutoGenName(const Name, Fmt: string; When: TDateTime): string;

{ -kf: BLAKE2b-256 del contenido del archivo clave, en hex (64 caracteres en minúscula).
  Lanza EFOpenError / Exception (archivo vacío). }
function KeyFileDigest(const FileName: string): string;
{ La contraseña que se le pasa a Argon2id con -kf (FORMATO-PARC.md §3b):
  Pwd (UTF-8) ‖ 0x00 ‖ "PArc/1 keyfile:" ‖ hex(digest). Sin -kf (Digest = ''), Pwd. }
function MixKeyFile(const Pwd, Digest: string): string;

implementation

uses
  parc_extract, parc_blake2;

function DefaultSelect: TSelectOptions;
begin
  Result := Default(TSelectOptions);
  Result.SizeMore := -1;
  Result.SizeLess := -1;
  Result.Dirs := dmAuto;
end;

function ContentFilters(const S: TSelectOptions): Boolean;
begin
  Result := S.IncludeGiven or (S.SizeMore >= 0) or (S.SizeLess >= 0) or S.HasAfter or S.HasBefore;
end;

function Selected(const S: TSelectOptions; const Name: string; IsDir: Boolean; Size, MTimeNs: Int64;
  UsePatterns: Boolean): Boolean;
begin
  Result := False;
  if IsDir then
  begin
    if S.Dirs = dmNever then Exit;
    if (S.Dirs = dmAuto) and ContentFilters(S) then Exit;
  end;
  if UsePatterns and (S.Patterns <> nil) and (S.Patterns.Count > 0) and not MatchesAny(Name, S.Patterns) then Exit;
  if MatchesAny(Name, S.Excludes) then Exit;
  if not IsDir then
  begin
    if S.IncludeGiven and not MatchesAny(Name, S.Includes) then Exit;
    if (S.SizeMore >= 0) and not (Size > S.SizeMore) then Exit;
    if (S.SizeLess >= 0) and not (Size < S.SizeLess) then Exit;
    if S.HasAfter and not (MTimeNs >= S.TimeAfter) then Exit;
    if S.HasBefore and not (MTimeNs < S.TimeBefore) then Exit;
  end;
  Result := True;
end;

function UnderArcPath(const S: TSelectOptions; const Name: string; out Rel: string): Boolean;
var
  P: string;
begin
  Rel := Name;
  if S.ArcPath = '' then Exit(True);
  P := S.ArcPath + '/';
  {$IFDEF WINDOWS}
  Result := LowerCase(Copy(Name, 1, Length(P))) = LowerCase(P);
  {$ELSE}
  Result := Copy(Name, 1, Length(P)) = P;
  {$ENDIF}
  if Result then Rel := Copy(Name, Length(P) + 1, MaxInt);
  if Rel = '' then Result := False;
end;

function SelectArchive(A: TArchive; const S: TSelectOptions): TBoolArray;
var
  i: Integer;
  Rel: string;
  Ns: Int64;
begin
  SetLength(Result, Length(A.Files));
  for i := 0 to High(A.Files) do
  begin
    Result[i] := False;
    if not UnderArcPath(S, A.Files[i].Name, Rel) then Continue;
    if A.Files[i].HasMTimeNs then Ns := A.Files[i].MTimeNs else Ns := A.Files[i].Time * 1000000000;
    Result[i] := Selected(S, Rel, A.Files[i].IsDir, A.Files[i].Size, Ns);
  end;
end;

function ParseSizeArg(const Text: string; DefMult: Int64; out V: Int64): Boolean;
var
  i: Integer;
  N: QWord;
  T: string;
  Mult: Int64;
begin
  Result := False;
  V := 0;
  T := LowerCase(Trim(Text));
  i := 1;
  N := 0;
  if (T = '') or not (T[1] in ['0'..'9']) then Exit;
  while (i <= Length(T)) and (T[i] in ['0'..'9']) do
  begin
    if N > QWord(High(Int64)) div 10 then Exit;
    N := N * 10 + QWord(Ord(T[i]) - Ord('0'));
    Inc(i);
  end;
  T := Copy(T, i, MaxInt);
  if T = '' then Mult := DefMult
  else if (T = 'b') then Mult := 1
  else if (T = 'k') or (T = 'kb') then Mult := 1 shl 10
  else if (T = 'm') or (T = 'mb') then Mult := 1 shl 20
  else if (T = 'g') or (T = 'gb') then Mult := 1 shl 30
  else Exit;
  if (N > 0) and (QWord(Mult) > QWord(High(Int64)) div N) then Exit;
  V := Int64(N) * Mult;
  Result := True;
end;

function ParseMemLimit(const Text: string; out V: Int64): Boolean;
var
  P: Int64;
begin
  if (Text <> '') and (Text[Length(Text)] = '%') then
  begin
    Result := ParseSizeArg(Copy(Text, 1, Length(Text) - 1), 1, P) and (P > 0) and (P <= 100) and (PhysicalMemory > 0);
    if Result then V := PhysicalMemory div 100 * P;
    Exit;
  end;
  Result := ParseSizeArg(Text, 1 shl 20, V) and (V > 0);
end;

function ParseAbsTime(const Text: string; out Ns: Int64): Boolean;
var
  D: string;
  i, Y, Mo, Dd, H, Mi, Se: Integer;
  T: TDateTime;
begin
  Result := False;
  Ns := 0;
  D := '';
  for i := 1 to Length(Text) do
    if Text[i] in ['0'..'9'] then D := D + Text[i]
    else if not (Text[i] in ['-', '_', ':', ' ', '.', 'T', '/']) then Exit;
  if (Length(D) < 8) or (Length(D) > 14) then Exit;
  while Length(D) < 14 do D := D + '0';
  Y := StrToInt(Copy(D, 1, 4)); Mo := StrToInt(Copy(D, 5, 2)); Dd := StrToInt(Copy(D, 7, 2));
  H := StrToInt(Copy(D, 9, 2)); Mi := StrToInt(Copy(D, 11, 2)); Se := StrToInt(Copy(D, 13, 2));
  if not TryEncodeDateTime(Y, Mo, Dd, H, Mi, Se, 0, T) then Exit;
  Ns := DateTimeToUnix(T, False) * 1000000000;
  Result := True;
end;

function ParsePeriod(const Text: string; out Ns: Int64): Boolean;
var
  i: Integer;
  N: Int64;
  Got: Boolean;
begin
  Result := False;
  Ns := 0;
  i := 1;
  if Text = '' then Exit;
  while i <= Length(Text) do
  begin
    N := 0;
    Got := False;
    while (i <= Length(Text)) and (Text[i] in ['0'..'9']) do
    begin
      if N > 100000000 then Exit;
      N := N * 10 + Ord(Text[i]) - Ord('0');
      Inc(i);
      Got := True;
    end;
    if not Got then Exit;
    if i > Length(Text) then begin Inc(Ns, N * 86400); Break; end;   // número solo: días
    case Text[i] of
      'w', 'W': Inc(Ns, N * 7 * 86400);
      'd', 'D': Inc(Ns, N * 86400);
      'h', 'H': Inc(Ns, N * 3600);
      'm', 'M': Inc(Ns, N * 60);
      's', 'S': Inc(Ns, N);
    else
      Exit;
    end;
    Inc(i);
  end;
  Ns := Ns * 1000000000;
  Result := True;
end;

function NowNs: Int64;
begin
  Result := DateTimeToUnix(Now, False) * 1000000000;
end;

procedure ReadListFile(const FileName: string; Dst: TStrings);
var
  L: TStringList;
  i: Integer;
  S: string;
begin
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(FsPath(FileName));
    except
      on E: Exception do
        raise EFOpenError.CreateFmt('could not read list file "%s"', [FileName]);
    end;
    for i := 0 to L.Count - 1 do
    begin
      S := L[i];
      if (i = 0) and (Copy(S, 1, 3) = #$EF#$BB#$BF) then Delete(S, 1, 3);
      S := Trim(S);
      if (S = '') or (S[1] = '#') then Continue;
      Dst.Add(S);
    end;
  finally
    L.Free;
  end;
end;

procedure AddItemOrList(const Item: string; Dst: TStrings);
begin
  if (Length(Item) > 1) and (Item[1] = '@') then ReadListFile(Copy(Item, 2, MaxInt), Dst)
  else Dst.Add(Item);
end;

function AutoGenName(const Name, Fmt: string; When: TDateTime): string;
var
  F, Stamp, Dir, Base, Ext: string;
  i, j, n: Integer;
  Y, Mo, D, H, Mi, S, Ms: Word;
begin
  F := Fmt;
  if F = '' then F := 'YYYYMMDDhhmmss';
  DecodeDateTime(When, Y, Mo, D, H, Mi, S, Ms);
  Stamp := '';
  i := 1;
  while i <= Length(F) do
  begin
    j := i;
    while (j <= Length(F)) and (F[j] = F[i]) do Inc(j);
    n := j - i;
    case F[i] of
      'Y': if n = 2 then Stamp := Stamp + Format('%.2d', [Y mod 100]) else Stamp := Stamp + Format('%.4d', [Y]);
      'M': Stamp := Stamp + Format('%.2d', [Mo]);
      'D': Stamp := Stamp + Format('%.2d', [D]);
      'h': Stamp := Stamp + Format('%.2d', [H]);
      'm': Stamp := Stamp + Format('%.2d', [Mi]);
      's': Stamp := Stamp + Format('%.2d', [S]);
    else
      Stamp := Stamp + Copy(F, i, n);
    end;
    i := j;
  end;
  Dir := ExtractFilePath(Name);
  Base := ExtractFileName(Name);
  Ext := ExtractFileExt(Base);
  Base := Copy(Base, 1, Length(Base) - Length(Ext));
  Result := Dir + Base + Stamp + Ext;
end;

function KeyFileDigest(const FileName: string): string;
var
  F: TFileStream;
  St: TBlake2b;
  Buf: array of Byte;
  n: LongInt;
  Total: Int64;
  D: array[0..31] of Byte;
  i: Integer;
begin
  try
    F := TFileStream.Create(FsPath(FileName), fmOpenRead or fmShareDenyWrite);
  except
    raise EFOpenError.CreateFmt('could not open key file "%s"', [FileName]);
  end;
  try
    Blake2bInit(St, 32);
    SetLength(Buf, 1 shl 16);
    Total := 0;
    repeat
      n := F.Read(Buf[0], Length(Buf));
      if n > 0 then Blake2bUpdate(St, @Buf[0], n);
      Inc(Total, n);
    until n <= 0;
    if Total = 0 then raise Exception.CreateFmt('key file "%s" is empty', [FileName]);
    Blake2bFinal(St, @D[0]);
    Result := '';
    for i := 0 to 31 do Result := Result + LowerCase(IntToHex(D[i], 2));
  finally
    F.Free;
  end;
end;

function MixKeyFile(const Pwd, Digest: string): string;
begin
  if Digest = '' then Exit(Pwd);
  Result := Pwd + #0'PArc/1 keyfile:' + Digest;
end;

end.
