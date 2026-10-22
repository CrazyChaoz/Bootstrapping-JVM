package net.jpountz.lz4;

final class LZ4Decoder {
  private LZ4Decoder() {}

  /** Decodes one LZ4 block; returns {bytes read, bytes written}. */
  static int[] decode(byte[] src, int srcOff, int srcEnd, byte[] dest, int destOff, int destEnd, boolean stopAtDestEnd) {
    int s = srcOff, d = destOff;
    while (true) {
      if (s >= srcEnd) throw new LZ4Exception("Malformed input at " + s);
      int token = src[s++] & 0xFF;
      int litLen = token >>> 4;
      if (litLen == 15) {
        int b;
        do { b = src[s++] & 0xFF; litLen += b; } while (b == 255);
      }
      if (d + litLen > destEnd || s + litLen > srcEnd) throw new LZ4Exception("Malformed input at " + s);
      System.arraycopy(src, s, dest, d, litLen);
      s += litLen; d += litLen;
      if ((stopAtDestEnd && d == destEnd) || (!stopAtDestEnd && s == srcEnd)) break;
      int offset = (src[s] & 0xFF) | ((src[s + 1] & 0xFF) << 8);
      s += 2;
      if (offset == 0 || d - offset < destOff) throw new LZ4Exception("Malformed input at " + s);
      int matchLen = token & 0x0F;
      if (matchLen == 15) {
        int b;
        do { b = src[s++] & 0xFF; matchLen += b; } while (b == 255);
      }
      matchLen += 4;
      if (d + matchLen > destEnd) throw new LZ4Exception("Malformed input at " + s);
      for (int i = 0; i < matchLen; i++, d++) dest[d] = dest[d - offset];
    }
    return new int[] { s - srcOff, d - destOff };
  }
}
