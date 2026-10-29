object Hello {
  def fib(n: Int): Int = if (n < 2) n else fib(n - 1) + fib(n - 2);
  def main(args: Array[String]): Unit = {
    val xs = List(1, 2, 3, 4, 5);
    System.out.println("Hello from a from-source 2003 scalac: " + xs.map(x => fib(x * 3)));
    xs match {
      case List(a, b, _*) => System.out.println("first two: " + a + ", " + b);
      case _ => System.out.println("??");
    }
  }
}
