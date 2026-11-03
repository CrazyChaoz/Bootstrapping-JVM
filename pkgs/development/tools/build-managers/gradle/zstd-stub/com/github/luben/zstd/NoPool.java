package com.github.luben.zstd;

import java.nio.ByteBuffer;

/** Compile-time stub of zstd-jni. */
public class NoPool implements BufferPool {
  public static final BufferPool INSTANCE = new NoPool();
  public ByteBuffer get(int capacity) { return ByteBuffer.allocate(capacity); }
  public void release(ByteBuffer buffer) { }
}
