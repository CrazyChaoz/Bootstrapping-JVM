package com.google.inject;

/** Compile-time stub of Guice for TestNG (Guice support is not used by Gradle). */
public interface Injector {
  <T> T getInstance(Class<T> type);
}
