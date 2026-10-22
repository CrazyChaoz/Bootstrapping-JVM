package net.jpountz.lz4;

import java.nio.ByteBuffer;

/** Emits a single LZ4 sequence holding all input as literals. */
public class LZ4Compressor {
  public static int maxCompressedLength(int length) {
    if (length < 0) throw new IllegalArgumentException("length must be >= 0, got " + length);
    return length + length / 255 + 16;
  }

  public final int maxCompressedLength0(int length) { return maxCompressedLength(length); }

  public int compress(byte[] src, int srcOff, int srcLen, byte[] dest, int destOff, int maxDestLen) {
    int d = destOff;
    int destEnd = destOff + maxDestLen;
    if (srcLen >= 15) {
      dest[d++] = (byte) 0xF0;
      int rest = srcLen - 15;
      while (rest >= 255) { dest[d++] = (byte) 0xFF; rest -= 255; }
      dest[d++] = (byte) rest;
    } else {
      dest[d++] = (byte) (srcLen << 4);
    }
    if (d + srcLen > destEnd) throw new LZ4Exception("maxDestLen is too small");
    System.arraycopy(src, srcOff, dest, d, srcLen);
    return d + srcLen - destOff;
  }

  public final int compress(byte[] src, int srcOff, int srcLen, byte[] dest, int destOff) {
    return compress(src, srcOff, srcLen, dest, destOff, dest.length - destOff);
  }

  public final byte[] compress(byte[] src, int srcOff, int srcLen) {
    byte[] dest = new byte[maxCompressedLength(srcLen)];
    int n = compress(src, srcOff, srcLen, dest, 0);
    return java.util.Arrays.copyOf(dest, n);
  }

  public final byte[] compress(byte[] src) { return compress(src, 0, src.length); }

  public final void compress(ByteBuffer src, ByteBuffer dest) {
    byte[] in = new byte[src.remaining()];
    src.get(in);
    byte[] out = compress(in);
    dest.put(out);
  }
}
