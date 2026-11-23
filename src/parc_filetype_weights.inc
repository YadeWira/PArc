{ Weights of the '$text' score of parc_filetype: a logistic fit (weighted by the bytes at
  stake) on the sample corpus, see the header of parc_filetype.pas. H0/H1 in 1/256 bit per
  byte, the rest per 1024 bytes; the score is compared with TEXT_BIAS. }
  W_H0 = -204;
  W_H1 = -8;
  W_LETTERS = 409;
  W_HIT3 = -361;
  W_HIT5 = -44;
  W_MATCH = 235;
  TEXT_LETTER_STEP = 307;
  W_LETTER_STEP = 13518;
  TEXT_BIAS = -158029;
  W_SPACES = 0;
  W_CONTROLS = 0;
