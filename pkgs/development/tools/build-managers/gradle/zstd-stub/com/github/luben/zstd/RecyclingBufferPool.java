package com.github.luben.zstd;

/** Compile-time stub of zstd-jni. */
public class RecyclingBufferPool extends NoPool {
  public static final BufferPool INSTANCE = new RecyclingBufferPool();
}
