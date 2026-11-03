/* The smoke test of the PiCo build: an algebraic type with a pattern match. */
public class Hello {
    static class Expr {
        case Num(int value);
        case Add(Expr left, Expr right);

        int eval() {
            switch (this) {
            case Num(int v):
                return v;
            case Add(Expr l, Expr r):
                return l.eval() + r.eval();
            default:
                throw new Error("no case");
            }
        }
    }

    public static void main(String[] args) {
        Expr e = Expr.Add(Expr.Num(40), Expr.Add(Expr.Num(1), Expr.Num(1)));
        System.out.println("Hello from PiCo: " + e.eval());
    }
}
