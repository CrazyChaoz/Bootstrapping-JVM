package smoke;

import smoke.lib.Fib;

public final class Main {
    public static void main(String[] args) {
        System.out.println("Hello from a from-source Gradle: fib(30) = " + Fib.fib(30));
    }
}
