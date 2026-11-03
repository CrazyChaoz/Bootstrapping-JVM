package net.jpountz.lz4;

/** Decompresses when the length of the compressed data is known. */
public class LZ4SafeDecompressor {
  public int decompress(byte[] src, int srcOff, int srcLen, byte[] dest, int destOff, int maxDestLen) {
    return LZ4Decoder.decode(src, srcOff, srcOff + srcLen, dest, destOff, destOff + maxDestLen, false)[1];
  }

  public final int decompress(byte[] src, int srcOff, int srcLen, byte[] dest, int destOff) {
    return decompress(src, srcOff, srcLen, dest, destOff, dest.length - destOff);
  }

  public final byte[] decompress(byte[] src, int srcOff, int srcLen, int maxDestLen) {
    byte[] dest = new byte[maxDestLen];
    int n = decompress(src, srcOff, srcLen, dest, 0, maxDestLen);
    return java.util.Arrays.copyOf(dest, n);
  }
}
