{ Presets de compresión (-m1..-m9, -mx, ...) y grupos de archivos, como FreeArc 0.67.
  Port de decode_method y compañía (Compression.hs): la tabla de sustituciones y arc.groups son
  las de FreeArc textuales (parc_presets_data.inc, generado por tools/gen_presets.py).

  Ejemplo: "5" -> [("", "rep:96m+exe+delta+lzma:96m:normal:32:mc32"),
                   ("$obj", "rep:96m+lzma:..."), ("$text", "dict:p:64m:80%+lzp:...+ppmd:12:192m"), ...]
  Con varios núcleos, las alternativas "a|b" eligen las variantes multihilo (4x4). }
unit parc_presets;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TGroupMethod = record
    Group: string;     // '' = por defecto; si no, '$text', '$obj', '$wav', ...
    Method: string;    // cadena de etapas unidas con '+'
  end;
  TGroupMethods = array of TGroupMethod;

{ decode_method: expande un -m (p. ej. "5", "9x", "lzma", "3/$obj=2b") a métodos por grupo. El
  primero es el de por defecto. Cpus elige entre alternativas "a|b||c". }
function DecodeMethod(const Str: string; Cpus: Integer): TGroupMethods;

{ Grupo de arc.groups de un nombre de archivo ('$text', '$exe', ...; '$default' si ninguno). }
function FileGroup(const Name: string): string;

{ Método para un grupo: el específico si existe, si no el de por defecto. }
function MethodForGroup(const GM: TGroupMethods; const Group: string): string;

{ Posición del grupo en arc.groups (para ordenar los archivos de un bloque sólido). }
function GroupOrder(const Group: string): Integer;

{ Las líneas de arc.groups tal cual (encabezados "$grupo" y máscaras, sin comentarios), en
  orden: FreeArc numera los grupos por línea (find_group, Cmdline.hs). }
function ArcGroupLines: TStringArray;

implementation

{$I parc_presets_data.inc}

type
  TSubst = record
    Key, Value: string;
  end;
  TSubstList = array of TSubst;

var
  Substs: TSubstList;
  SubstsCpus: Integer = -1;
  GroupNames: TStringList;    // grupos en orden de arc.groups
  GroupPatterns: TStringList; // patrón -> índice de grupo (en Objects), en orden

function Split(const S: string; Sep: Char): TStringArray;
begin
  Result := S.Split([Sep]);
  if Length(Result) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := '';
  end;
end;

{ split2: parte en el primer Sep; si no está, (S, ''). }
procedure Split2(const S: string; Sep: Char; out A, B: string);
var
  p: Integer;
begin
  p := Pos(Sep, S);
  if p = 0 then begin A := S; B := ''; end
  else begin A := Copy(S, 1, p - 1); B := Copy(S, p + 1, MaxInt); end;
end;

{ select_by: en "(A|B||D)" elige la alternativa por cantidad de CPUs: A con 1, B con 2 y 3,
  D con 4 o más (una alternativa vacía repite la anterior). Resuelve paréntesis anidados. }
function SelectBy(const S: string; Cpus: Integer): string;
var
  Open, Close, i, k: Integer;
  Alts: TStringArray;
  Last, Pick: string;
begin
  Result := S;
  while True do
  begin
    // El paréntesis de cierre más a la izquierda y su apertura: el grupo más interno
    Close := Pos(')', Result);
    if Close = 0 then Break;
    Open := 0;
    for i := Close - 1 downto 1 do
      if Result[i] = '(' then begin Open := i; Break; end;
    if Open = 0 then Break;
    Alts := Split(Copy(Result, Open + 1, Close - Open - 1), '|');
    Last := '';
    Pick := '';
    for k := 0 to Cpus - 1 do
    begin
      if k <= High(Alts) then
      begin
        if Alts[k] <> '' then Last := Alts[k];
      end;
      Pick := Last;
    end;
    Result := Copy(Result, 1, Open - 1) + Pick + Copy(Result, Close + 1, MaxInt);
  end;
end;

function SelectFullBy(const S: string; Cpus: Integer): string;
begin
  Result := SelectBy('(' + S + ')', Cpus);
end;

{ prepareSubsts + reorder: sin comentarios ni espacios, cada '#' en 9 variantes (1..9), primero
  las líneas sin '#' y después las que tienen (las concretas ganan a las generales). }
procedure BuildSubsts(Cpus: Integer);
var
  Plain, Hashed: TStringList;
  i: Integer;
  d: Char;

  procedure AddLine(const Raw: string);
  var
    L, A, B, c: string;
    j: Integer;
  begin
    Split2(Raw, ';', L, A);
    c := '';
    for j := 1 to Length(L) do
      if not (L[j] in [' ', #9]) then c := c + L[j];
    if c = '' then Exit;
    Split2(c, '=', A, B);
    SetLength(Substs, Length(Substs) + 1);
    Substs[High(Substs)].Key := A;
    Substs[High(Substs)].Value := SelectFullBy(B, Cpus);
  end;

begin
  Substs := nil;
  Plain := TStringList.Create;
  Hashed := TStringList.Create;
  try
    for i := 0 to High(BUILTIN_METHOD_SUBSTS) do
      if Pos('#', BUILTIN_METHOD_SUBSTS[i]) > 0 then Hashed.Add(BUILTIN_METHOD_SUBSTS[i])
      else Plain.Add(BUILTIN_METHOD_SUBSTS[i]);
    for i := 0 to Plain.Count - 1 do AddLine(Plain[i]);
    for i := 0 to Hashed.Count - 1 do
      for d := '1' to '9' do
        AddLine(StringReplace(Hashed[i], '#', d, [rfReplaceAll]));
  finally
    Plain.Free;
    Hashed.Free;
  end;
  SubstsCpus := Cpus;
end;

function Lookup(const Key: string; out Value: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Substs) do
    if Substs[i].Key = Key then
    begin
      Value := Substs[i].Value;
      Exit(True);
    end;
  Result := False;
end;

{ subst: expande el método principal (antes del primer '/') recursivamente y agrega las
  definiciones por grupo de la forma "<main>$grupo=..." (p. ej. "5$wav" para "5"). }
function Subst(const Method: string): string;
var
  Parts: TStringArray;
  Main, MainMethods, V, Joined: string;
  Seen: TStringList;
  i: Integer;
begin
  Parts := Split(Method, '/');
  Main := Parts[0];
  if Lookup(Main, V) then MainMethods := Subst(V) else MainMethods := Main;
  Result := MainMethods;
  Seen := TStringList.Create;
  try
    for i := 0 to High(Substs) do
    begin
      if Seen.IndexOf(Substs[i].Key) >= 0 then Continue;   // keepOnlyFirstOn fst
      Seen.Add(Substs[i].Key);
      Joined := Substs[i].Key + '=' + Substs[i].Value;
      if (Main <> '') and (Copy(Joined, 1, Length(Main)) = Main) and
         (Copy(Joined, Length(Main) + 1, 1) = '$') then
        Result := Result + '/' + Copy(Joined, Length(Main) + 1, MaxInt);
    end;
  finally
    Seen.Free;
  end;
  for i := 1 to High(Parts) do Result := Result + '/' + Parts[i];
end;

{ subst2: expande cada etapa de un compresor ("5binary:xx" -> la definición de 5binary + ":xx"). }
function Subst2(const Method: string): string;
var
  Stages: TStringArray;
  Head, Params, V, R: string;
  i: Integer;
begin
  Result := '';
  if Method = '' then Exit;
  Stages := Split(Method, '+');
  for i := 0 to High(Stages) do
  begin
    Head := Stages[i];
    Params := '';
    if Pos(':', Head) > 0 then
    begin
      Params := Copy(Head, Pos(':', Head), MaxInt);
      Head := Copy(Head, 1, Pos(':', Head) - 1);
    end;
    if Lookup(Head, V) then R := Subst2(V + Params) else R := Stages[i];
    if R = '' then Continue;
    if Result <> '' then Result := Result + '+';
    Result := Result + R;
  end;
end;

function DecodeMethod(const Str: string; Cpus: Integer): TGroupMethods;
var
  S: string;
  Parts: TStringArray;
  Raw: array of TGroupMethod;
  i, j, n: Integer;
  Dup: Boolean;

  procedure AddRaw(const G, M: string);
  begin
    SetLength(Raw, Length(Raw) + 1);
    Raw[High(Raw)].Group := G;
    Raw[High(Raw)].Method := M;
  end;

begin
  if Cpus < 1 then Cpus := 1;
  if SubstsCpus <> Cpus then BuildSubsts(Cpus);
  S := Subst(SelectFullBy(Str, Cpus));
  // split_to_methods
  Raw := nil;
  Parts := Split(S, '/');
  if Length(Parts) = 1 then
    AddRaw('', S)
  else if Copy(Parts[1], 1, 1) = '$' then
  begin
    // "m1/$grupo=m2/...": el primero es el de por defecto
    AddRaw('', Parts[0]);
    for i := 1 to High(Parts) do
    begin
      AddRaw('', '');
      Split2(Parts[i], '=', Raw[High(Raw)].Group, Raw[High(Raw)].Method);
    end;
  end
  else
  begin
    // "b/t/..." : el primero es para binarios (con exe), el segundo para textos
    AddRaw('', 'exe+' + Parts[0]);
    AddRaw('$obj', Parts[0]);
    AddRaw('$text', Parts[1]);
    for i := 2 to High(Parts) do
    begin
      AddRaw('', '');
      Split2(Parts[i], '=', Raw[High(Raw)].Group, Raw[High(Raw)].Method);
    end;
  end;
  // keepOnlyLastOn fst: de cada grupo queda la última definición, en su posición
  Result := nil;
  for i := 0 to High(Raw) do
  begin
    Dup := False;
    for j := i + 1 to High(Raw) do
      if Raw[j].Group = Raw[i].Group then Dup := True;
    if Dup then Continue;
    S := Subst2(SelectFullBy(Raw[i].Method, Cpus));
    if S = '' then Continue;   // "-m$bmp=" desactiva el método especial del grupo
    n := Length(Result);
    SetLength(Result, n + 1);
    Result[n].Group := Raw[i].Group;
    Result[n].Method := S;
  end;
end;

function MethodForGroup(const GM: TGroupMethods; const Group: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(GM) do
    if GM[i].Group = '' then Result := GM[i].Method;
  for i := 0 to High(GM) do
    if (GM[i].Group <> '') and (GM[i].Group = Group) then Exit(GM[i].Method);
end;

{ ---- grupos (arc.groups) ---- }

procedure LoadGroups;
var
  i, Cur: Integer;
  L: string;
begin
  GroupNames := TStringList.Create;
  GroupPatterns := TStringList.Create;
  Cur := -1;
  for i := 0 to High(ARC_GROUPS) do
  begin
    L := ARC_GROUPS[i];
    if Copy(L, 1, 1) = '$' then
      Cur := GroupNames.Add(L)
    else if Cur >= 0 then
      GroupPatterns.AddObject(LowerCase(L), TObject(PtrInt(Cur)));
  end;
end;

function MatchWild(const Name, Mask: string): Boolean;
var
  n, m, StarM, StarN: Integer;
begin
  n := 1; m := 1; StarM := 0; StarN := 0;
  while n <= Length(Name) do
  begin
    if (m <= Length(Mask)) and ((Mask[m] = '?') or (Mask[m] = Name[n])) then
    begin
      Inc(n); Inc(m);
    end
    else if (m <= Length(Mask)) and (Mask[m] = '*') then
    begin
      StarM := m; StarN := n; Inc(m);
    end
    else if StarM > 0 then
    begin
      m := StarM + 1; Inc(StarN); n := StarN;
    end
    else
      Exit(False);
  end;
  while (m <= Length(Mask)) and (Mask[m] = '*') do Inc(m);
  Result := m > Length(Mask);
end;

function FileGroup(const Name: string): string;
var
  Base: string;
  i: Integer;
begin
  Base := LowerCase(Copy(Name, LastDelimiter('/', Name) + 1, MaxInt));
  // "*." en arc.groups es "sin extensión": un nombre sin punto se compara como "nombre."
  if Pos('.', Base) = 0 then Base := Base + '.';
  for i := 0 to GroupPatterns.Count - 1 do
    if MatchWild(Base, GroupPatterns[i]) then
      Exit(GroupNames[PtrInt(GroupPatterns.Objects[i])]);
  Result := '$default';
end;

function GroupOrder(const Group: string): Integer;
begin
  Result := GroupNames.IndexOf(Group);
  if Result < 0 then Result := GroupNames.IndexOf('$default');
end;

function ArcGroupLines: TStringArray;
var
  i: Integer;
begin
  SetLength(Result, Length(ARC_GROUPS));
  for i := 0 to High(ARC_GROUPS) do Result[i] := ARC_GROUPS[i];
end;

initialization
  LoadGroups;
finalization
  GroupNames.Free;
  GroupPatterns.Free;
end.
