{ Mapa string -> entero con direccionamiento abierto (FNV-1a). Para índices por nombre en listas
  grandes (directorio, orden de archivos) donde TStringList.IndexOf es O(n) por búsqueda. }
unit parc_strmap;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

type
  TStrIntMap = object
  private
    FKeys: array of string;
    FVals: array of Integer;
    FUsed: array of Boolean;
    FCount, FMask: Integer;
    function Slot(const Key: string): Integer;
    procedure Grow;
  public
    procedure Init(Capacity: Integer = 16);
    { Valor de Key, o Default si no está. }
    function Get(const Key: string; Default: Integer = -1): Integer;
    { Pone (o reemplaza) el valor de Key. }
    procedure Put(const Key: string; Value: Integer);
    property Count: Integer read FCount;
  end;

implementation

function HashStr(const S: string): LongWord; inline;
var
  i: Integer;
begin
  Result := 2166136261;
  for i := 1 to Length(S) do
    Result := (Result xor Byte(S[i])) * 16777619;
end;

procedure TStrIntMap.Init(Capacity: Integer);
var
  n: Integer;
begin
  n := 16;
  while n < Capacity * 2 do n := n * 2;
  SetLength(FKeys, n);
  SetLength(FVals, n);
  SetLength(FUsed, n);
  FillChar(FUsed[0], n, 0);
  FCount := 0;
  FMask := n - 1;
end;

function TStrIntMap.Slot(const Key: string): Integer;
begin
  Result := HashStr(Key) and FMask;
  while FUsed[Result] and (FKeys[Result] <> Key) do
    Result := (Result + 1) and FMask;
end;

procedure TStrIntMap.Grow;
var
  OldKeys: array of string;
  OldVals: array of Integer;
  OldUsed: array of Boolean;
  i, s: Integer;
begin
  OldKeys := FKeys; OldVals := FVals; OldUsed := FUsed;
  FKeys := nil; FVals := nil; FUsed := nil;
  Init(Length(OldKeys));
  for i := 0 to High(OldKeys) do
    if OldUsed[i] then
    begin
      s := Slot(OldKeys[i]);
      FUsed[s] := True;
      FKeys[s] := OldKeys[i];
      FVals[s] := OldVals[i];
      Inc(FCount);
    end;
end;

function TStrIntMap.Get(const Key: string; Default: Integer): Integer;
var
  s: Integer;
begin
  if FMask = 0 then Exit(Default);
  s := Slot(Key);
  if FUsed[s] then Result := FVals[s] else Result := Default;
end;

procedure TStrIntMap.Put(const Key: string; Value: Integer);
var
  s: Integer;
begin
  if FMask = 0 then Init;
  if (FCount + 1) * 2 > FMask + 1 then Grow;
  s := Slot(Key);
  if not FUsed[s] then
  begin
    FUsed[s] := True;
    FKeys[s] := Key;
    Inc(FCount);
  end;
  FVals[s] := Value;
end;

end.
