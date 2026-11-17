program ptest;
{ Primitivas de cifrado de PArc por un protocolo de líneas (el mismo que tests/crypto/oracle.py).
  Hex en minúsculas; "-" = vacío. Una línea de respuesta por línea de entrada:

    B2 <outlen> <clave> <msg>                         BLAKE2b
    A2 <d|i|id> <t> <mKiB> <p> <taglen> <pwd> <sal> <secreto> <ad>   Argon2
    CC <clave32> <nonce12> <contador> <msg>           ChaCha20 (xor)
    HC <clave32> <nonce16>                            HChaCha20
    P5 <clave32> <msg>                                Poly1305
    CP <clave32> <nonce12> <ad> <msg>                 ChaCha20-Poly1305: cifrado||etiqueta
    XC <clave32> <nonce24> <ad> <msg>                 XChaCha20-Poly1305
    GC <clave32> <nonce12> <ad> <msg>                 AES-256-GCM
    CO|XO|GO <clave32> <nonce> <ad> <cifrado||etiqueta>   abrir: el claro o FAIL
    AE <clave32> <bloque16>                           AES-256 (un bloque)
    T <hilos>                                         hilos para Argon2 (default 1) }
{$mode objfpc}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, parc_blake2, parc_chacha, parc_aes;

function Unhex(const S: string): TBytes;
var i: Integer;
begin
  Result := nil;
  if S = '-' then Exit;
  SetLength(Result, Length(S) div 2);
  for i := 0 to High(Result) do Result[i] := StrToInt('$' + Copy(S, 2 * i + 1, 2));
end;

function Hex(const B: TBytes): string;
const D: array[0..15] of Char = '0123456789abcdef';
var i: Integer;
begin
  SetLength(Result, 2 * Length(B));
  for i := 0 to High(B) do
  begin
    Result[2 * i + 1] := D[B[i] shr 4];
    Result[2 * i + 2] := D[B[i] and 15];
  end;
  if Result = '' then Result := '-';
end;

function P(const B: TBytes): PByte;
begin
  if Length(B) = 0 then Result := nil else Result := @B[0];
end;

var
  L: string;
  F: TStringArray;
  K, N, A, M, O, T: TBytes;
  Kind: TArgon2Type;
  Threads: Integer = 1;
  G: TAesGcmKey;
  ok: Boolean;
begin
  while not EOF(Input) do
  begin
    ReadLn(L);
    F := L.Split([' ']);
    if Length(F) = 0 then Continue;
    case F[0] of
      'T': begin Threads := StrToInt(F[1]); WriteLn('ok'); end;
      'B2':
        begin
          K := Unhex(F[2]); M := Unhex(F[3]);
          SetLength(O, StrToInt(F[1]));
          Blake2b(@O[0], Length(O), P(M), Length(M), P(K), Length(K));
          WriteLn(Hex(O));
        end;
      'A2':
        begin
          case F[1] of 'd': Kind := a2d; 'i': Kind := a2i; else Kind := a2id; end;
          K := Unhex(F[6]); N := Unhex(F[7]); A := Unhex(F[8]); M := Unhex(F[9]);
          SetLength(O, StrToInt(F[5]));
          Argon2(Kind, P(K), Length(K), P(N), Length(N), StrToInt(F[2]), StrToInt(F[3]), StrToInt(F[4]),
                 @O[0], Length(O), P(A), Length(A), P(M), Length(M), Threads);
          WriteLn(Hex(O));
        end;
      'CC':
        begin
          K := Unhex(F[1]); N := Unhex(F[2]); M := Unhex(F[4]);
          SetLength(O, Length(M));
          ChaCha20Xor(@K[0], @N[0], LongWord(StrToInt64(F[3])), P(M), P(O), Length(M));
          WriteLn(Hex(O));
        end;
      'HC':
        begin
          K := Unhex(F[1]); N := Unhex(F[2]);
          SetLength(O, 32);
          HChaCha20(@K[0], @N[0], @O[0]);
          WriteLn(Hex(O));
        end;
      'P5':
        begin
          K := Unhex(F[1]); M := Unhex(F[2]);
          SetLength(O, 16);
          Poly1305Mac(@K[0], P(M), Length(M), @O[0]);
          WriteLn(Hex(O));
        end;
      'AE':
        begin
          K := Unhex(F[1]); M := Unhex(F[2]);
          SetLength(O, 16);
          Aes256EncryptBlock(@K[0], @M[0], @O[0]);
          WriteLn(Hex(O));
        end;
      'CP', 'XC', 'GC':
        begin
          K := Unhex(F[1]); N := Unhex(F[2]); A := Unhex(F[3]); M := Unhex(F[4]);
          SetLength(O, Length(M) + 16);
          case F[0] of
            'CP': ChaChaPolySeal(@K[0], @N[0], P(A), Length(A), P(M), P(O), Length(M), @O[Length(M)]);
            'XC': XChaChaPolySeal(@K[0], @N[0], P(A), Length(A), P(M), P(O), Length(M), @O[Length(M)]);
            'GC':
              begin
                AesGcmInit(G, @K[0]);
                AesGcmSeal(G, @N[0], P(A), Length(A), P(M), P(O), Length(M), @O[Length(M)]);
              end;
          end;
          WriteLn(Hex(O));
        end;
      'CO', 'XO', 'GO':
        begin
          K := Unhex(F[1]); N := Unhex(F[2]); A := Unhex(F[3]); M := Unhex(F[4]);
          SetLength(O, Length(M) - 16);
          case F[0] of
            'CO': ok := ChaChaPolyOpen(@K[0], @N[0], P(A), Length(A), P(M), P(O), Length(O), @M[Length(O)]);
            'XO': ok := XChaChaPolyOpen(@K[0], @N[0], P(A), Length(A), P(M), P(O), Length(O), @M[Length(O)]);
          else
            AesGcmInit(G, @K[0]);
            ok := AesGcmOpen(G, @N[0], P(A), Length(A), P(M), P(O), Length(O), @M[Length(O)]);
          end;
          if ok then WriteLn(Hex(O)) else WriteLn('FAIL');
        end;
    else
      WriteLn('?');
    end;
  end;
end.
