package com.google.inject;

/** Compile-time stub of Guice for TestNG (Guice support is not used by Gradle). */
public final class Guice {
  private Guice() { }
  public static Injector createInjector(Iterable<? extends Module> modules) {
    throw new UnsupportedOperationException("Guice is not available");
  }
}
