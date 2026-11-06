package smoke

/** Compiled by Zinc together with Greeter.java (joint compilation). */
object Main {
  def fib(n: Int): BigInt = LazyList.iterate((BigInt(0), BigInt(1))) { case (a, b) => (b, a + b) }(n)._1

  def main(args: Array[String]): Unit =
    println(s"${Greeter.greet("Scala " + scala.util.Properties.versionNumberString)}: fib(90) = ${fib(90)}")
}
