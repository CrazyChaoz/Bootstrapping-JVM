package net.jpountz.lz4;

/**
 * Minimal stand-in for lz4-java (whose Java sources are generated from MVEL
 * templates): the API subset used by the IntelliJ platform, implemented with
 * a plain LZ4 block decoder and a literal-only (but valid) LZ4 block encoder.
 */
public final class LZ4Factory {
  private static final LZ4Factory INSTANCE = new LZ4Factory();
  private final LZ4Compressor compressor = new LZ4Compressor();
  private final LZ4FastDecompressor fastDecompressor = new LZ4FastDecompressor();
  private final LZ4SafeDecompressor safeDecompressor = new LZ4SafeDecompressor();

  private LZ4Factory() {}

  public static LZ4Factory fastestInstance() { return INSTANCE; }
  public static LZ4Factory fastestJavaInstance() { return INSTANCE; }
  public static LZ4Factory safeInstance() { return INSTANCE; }
  public static LZ4Factory unsafeInstance() { return INSTANCE; }
  public static LZ4Factory nativeInstance() { return INSTANCE; }

  public LZ4Compressor fastCompressor() { return compressor; }
  public LZ4Compressor highCompressor() { return compressor; }
  public LZ4Compressor highCompressor(int level) { return compressor; }
  public LZ4FastDecompressor fastDecompressor() { return fastDecompressor; }
  public LZ4SafeDecompressor safeDecompressor() { return safeDecompressor; }
}
