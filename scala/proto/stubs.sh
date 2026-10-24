if [ -n "${CLR_STUB:-}" ]; then
  mkdir -p stubs/scalac/symtab/classfile
  cat > stubs/scalac/symtab/classfile/CLRPackageParser.java <<'JAVA'
package scalac.symtab.classfile;
/** stub: the MSIL backend is not bootstrapped */
public class CLRPackageParser {
    public static CLRPackageParser create(Object global) { return null; }
    public static CLRPackageParser instance(Object global) { return null; }
    public static CLRPackageParser instance() { return null; }
    public void importCLRTypes(Object... args) {
        throw new Error("MSIL support is not available");
    }
}
JAVA
fi
