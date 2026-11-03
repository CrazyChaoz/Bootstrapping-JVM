package com.github.luben.zstd;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;

/** Compile-time stub of zstd-jni (a JNI library); never on the runtime classpath. */
public class ZstdInputStream extends FilterInputStream {
  public ZstdInputStream(InputStream in) throws IOException {
    super(in);
    throw new UnsupportedOperationException("zstd-jni is not available");
  }
  public ZstdInputStream(InputStream in, BufferPool pool) throws IOException { this(in); }
}
