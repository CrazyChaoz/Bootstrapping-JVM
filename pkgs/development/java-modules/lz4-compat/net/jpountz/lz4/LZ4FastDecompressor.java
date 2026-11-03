package net.jpountz.lz4;

import java.nio.ByteBuffer;

/** Decompresses when the length of the original data is known. */
public class LZ4FastDecompressor {
  public int decompress(byte[] src, int srcOff, byte[] dest, int destOff, int destLen) {
    return LZ4Decoder.decode(src, srcOff, src.length, dest, destOff, destOff + destLen, true)[0];
  }

  public final int decompress(byte[] src, byte[] dest, int destLen) { return decompress(src, 0, dest, 0, destLen); }

  public final int decompress(byte[] src, byte[] dest) { return decompress(src, dest, dest.length); }

  public final byte[] decompress(byte[] src, int srcOff, int destLen) {
    byte[] dest = new byte[destLen];
    decompress(src, srcOff, dest, 0, destLen);
    return dest;
  }

  public final byte[] decompress(byte[] src, int destLen) { return decompress(src, 0, destLen); }

  public final void decompress(ByteBuffer src, ByteBuffer dest) {
    byte[] in = new byte[src.remaining()];
    src.duplicate().get(in);
    byte[] out = new byte[dest.remaining()];
    int read = decompress(in, 0, out, 0, out.length);
    src.position(src.position() + read);
    dest.put(out);
  }
}
