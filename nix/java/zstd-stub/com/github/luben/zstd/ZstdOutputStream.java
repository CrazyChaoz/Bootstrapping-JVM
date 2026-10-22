package com.github.luben.zstd;

import java.io.FilterOutputStream;
import java.io.IOException;
import java.io.OutputStream;

/** Compile-time stub of zstd-jni (a JNI library); never on the runtime classpath. */
public class ZstdOutputStream extends FilterOutputStream {
  public ZstdOutputStream(OutputStream out) throws IOException { this(out, 3); }
  public ZstdOutputStream(OutputStream out, int level) throws IOException { this(out, level, false); }
  public ZstdOutputStream(OutputStream out, int level, boolean closeFrameOnFlush) throws IOException { this(out, level, closeFrameOnFlush, false); }
  public ZstdOutputStream(OutputStream out, int level, boolean closeFrameOnFlush, boolean useChecksums) throws IOException {
    super(out);
    throw new UnsupportedOperationException("zstd-jni is not available");
  }
}
