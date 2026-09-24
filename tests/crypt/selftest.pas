program selftest;
{$mode objfpc}{$H+}
uses SysUtils, parc_bytes, parc_stream, parc_crypt;
var s: RawByteString; d: TBytes; pwd, salt: RawByteString; e: Integer;
function Hex(const b: array of Byte): string;
const H: array[0..15] of Char = '0123456789abcdef';
var i: Integer;
begin
  Result := '';
  for i := 0 to High(b) do Result := Result + H[b[i] shr 4] + H[b[i] and $F];
end;
procedure Chk(const que, got, esp: string);
begin
  if LowerCase(got) = LowerCase(esp) then WriteLn('OK   ', que) else
  begin WriteLn('MAL  ', que, '  got=', got, '  esp=', esp); Inc(e); end;
end;
begin
  e := 0;
  s := 'abc';  d := Sha512Data(@s[1], 3);
  Chk('sha512("abc")', Hex(d), 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f');
  d := Sha512Data(nil, 0);
  Chk('sha512("")', Hex(d), 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e');
  pwd := 'password'; salt := 'salt';
  Pbkdf2HmacSha512(@pwd[1], 8, @salt[1], 4, 4096, @d[0], 64);
  Chk('pbkdf2 c=4096', Hex(d), 'd197b1b33db0143e018b12f3d1d1479e6cdebdcc97c5c0f87f6902e072f457b5143f30602641b3d55cd335988cb36b84376060ecd532e039b742a239434af2d5');
  Chk('aes-128 FIPS', AesEcb('000102030405060708090a0b0c0d0e0f','00112233445566778899aabbccddeeff'), '69c4e0d86a7b0430d8cdb78070b4c55a');
  Chk('aes-192 FIPS', AesEcb('000102030405060708090a0b0c0d0e0f1011121314151617','00112233445566778899aabbccddeeff'), 'dda97ca4864cdfe06eaf70a0ec0d7191');
  Chk('aes-256 FIPS', AesEcb('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f','00112233445566778899aabbccddeeff'), '8ea2b7ca516745bfeafc49904b496089');
  { vectores de blowfish de la propia LibTomCrypt (blowfish_test) }
  Chk('blowfish v1', BlowfishTestVec('0000000000000000','0000000000000000'), '4ef997456198dd78');
  Chk('blowfish v2', BlowfishTestVec('ffffffffffffffff','ffffffffffffffff'), '51866fd5b85ecb8a');
  Chk('blowfish v3', BlowfishTestVec('3000000000000000','1000000000000001'), '7d856f9a613063f2');
  Chk('serpent k16-1', SerpentTestVec('00000000000000000000000000000000','d29d576fcea3a3a7ed9099f29273d78e'), 'b2288b968ae8b08648d1ce9606fd992d');
  Chk('serpent k16-2', SerpentTestVec('00000000000000000000000000000000','d29d576fcea3a3a7ed9099f26d8c2871'), '563a8403ff5309d62370b1dcf5a11edd');
  Chk('serpent k16-3', SerpentTestVec('ffeeddccbbaa99887766554433221100','1032547698badcfeefcdab8967452301'), 'd5baa00a4bb9d8a7c981c8dc90d89d92');
  Chk('serpent k16-4', SerpentTestVec('ffeeddccbbaa99887766554433221100','145f0b8b663176b95dcab7e9dcd5cc24'), '1032547698badcfeefcdab8967452301');
  Chk('serpent k24-1', SerpentTestVec('000000000000000000000000000000000000000000000000','d29d576fceaba3a7ed9899f2927bd78e'), '130e353e1037c22405e8faefb2c3c3e9');
  Chk('serpent k24-2', SerpentTestVec('8899aabbccddeeffffeeddccbbaa99887766554433221100','1032547698badcfeefcdab8967452301'), 'da860842b720802bf404a4c71034879a');
  Chk('serpent k24-3', SerpentTestVec('8899aabbccddeeffffeeddccbbaa99887766554433221100','b2696bd0d98c17953e4239225d27202c'), '1032547698badcfeefcdab8967452301');
  Chk('serpent k32-1', SerpentTestVec('0000000000000000000000000000000000000000000000000000000000000000','92074732d84e1841a013a0034c52bf50'), '81c4eb7b8ad9a8d0f2aa5d7bd626b560');
  Chk('serpent k32-2', SerpentTestVec('00112233445566778899aabbccddeeffffeeddccbbaa99887766554433221100','1032547698badcfeefcdab8967452301'), '93df9a3cafe387bd999eebe393a17fca');
  Chk('twofish v0 (16 bytes)'
      , TwofishTestVec('9f589f5cf6122c32b6bfec2f2ae8c35a','d491db16e7b1c39e86cb086b789f5419')
      , '019f9809de1711858faac3a3ba20fbc3');
  Chk('twofish v1 (24 bytes)'
      , TwofishTestVec('88b2b2706b105e36b446bb6d731a1e88efa71f788965bd44','39da69d6ba4997d585b6dc073ca341b2')
      , '182b02d81497ea45f9daacdc29193a65');
  Chk('twofish v2 (32 bytes)'
      , TwofishTestVec('d43bb7556ea32e46f2a282b7d45b4e0d57ff739d4dc92c1bd7fc01700cc8216f','90afe91bb288544f2c32dc239b2635e6')
      , '6cb4561c40bf0a9705931cb6d408e7fa');
  WriteLn('errores: ', e);
end.
