package com.github.luben.zstd;

import java.nio.ByteBuffer;

/** Compile-time stub of zstd-jni. */
public interface BufferPool {
  ByteBuffer get(int capacity);
  void release(ByteBuffer buffer);
}
