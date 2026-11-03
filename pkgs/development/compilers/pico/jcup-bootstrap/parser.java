package jcup;

import java.util.ArrayList;
import java.util.Hashtable;
import jcup.runtime.Symbol;

/** Stands in for JCup's generated specification parser (which needs the parse tables that this is
 *  to produce) while bootstrapping: reads the symbol declarations and productions of a JCup
 *  specification that uses no precedence, and builds them as the real parser's actions do.
 *  Everything before the declarations (package, import, code, init, scan) is skipped. */
public class parser {
    private final Hashtable symbols = new Hashtable();
    private final Hashtable nonTerms = new Hashtable();
    private Symbol tok;

    private void next() throws java.io.IOException { tok = lexer.next_token(); }

    private String id() throws java.io.IOException {
        if (tok.sym != sym.ID) throw new RuntimeException("identifier expected, found " + tok.sym);
        String s = (String) tok.value;
        next();
        return s;
    }

    private void expect(int s) throws java.io.IOException {
        if (tok.sym != s) throw new RuntimeException("token " + s + " expected, found " + tok.sym);
        next();
    }

    public Symbol parse() throws Exception {
        lexer.init();
        symbols.put("error", new symbol_part(terminal.error));
        nonTerms.put("$START", non_terminal.START_nt);
        next();
        while (tok.sym != sym.TERMINAL && tok.sym != sym.NON) next();
        while (tok.sym == sym.TERMINAL || tok.sym == sym.NON) declarations();
        if (tok.sym == sym.PRECEDENCE) throw new RuntimeException("precedence is not supported");
        expect(sym.START);
        expect(sym.WITH);
        non_terminal start = (non_terminal) nonTerms.get(id());
        expect(sym.SEMI);
        production_part[] parts = {new symbol_part(start, "start_val"), new symbol_part(terminal.EOF),
                                   new action_part("RESULT = start_val;")};
        emit.start_production = new production(non_terminal.START_nt, parts, 3);
        while (tok.sym != sym.EOF) productionRule();
        return null;
    }

    public Symbol debug_parse() throws Exception { return parse(); }

    /** terminal [type] id, id...;   non terminal [type] id, id...; */
    private void declarations() throws Exception {
        boolean terminals = tok.sym == sym.TERMINAL;
        if (!terminals) { next(); expect(sym.TERMINAL); } else next();
        ArrayList group = new ArrayList();
        String type = "Object";
        for (;; next()) {
            if (tok.sym == sym.ID) group.add(tok.value);
            else if (tok.sym == sym.COMMA || tok.sym == sym.SEMI) {
                if (group.isEmpty()) throw new RuntimeException("name expected");
                String name = (String) group.get(group.size() - 1);
                if (group.size() > 1 && type.equals("Object")) {
                    type = (String) group.get(0);
                    for (int i = 1; i < group.size() - 1; i++) type += "." + group.get(i);
                }
                if (symbols.get(name) != null) throw new RuntimeException(name + " declared twice");
                if (terminals) symbols.put(name, new symbol_part(new terminal(name, type)));
                else {
                    non_terminal nt = new non_terminal(name, type);
                    nonTerms.put(name, nt);
                    symbols.put(name, new symbol_part(nt));
                }
                group.clear();
                if (tok.sym == sym.SEMI) break;
            } else if (tok.sym != sym.DOT) throw new RuntimeException("unexpected token " + tok.sym);
        }
        next();
    }

    /** lhs ::= part... | part... ; where a part is  id[:label]  or an action */
    private void productionRule() throws Exception {
        non_terminal lhs = (non_terminal) nonTerms.get(id());
        expect(sym.COLON_COLON_EQUALS);
        ArrayList parts = new ArrayList();
        for (;;) {
            if (tok.sym == sym.ID) {
                String name = id();
                symbol_part p = (symbol_part) symbols.get(name);
                if (p == null) throw new RuntimeException(name + " is not declared");
                if (tok.sym == sym.COLON) { next(); p = new symbol_part(p.the_symbol(), id()); }
                parts.add(p);
            } else if (tok.sym == sym.CODE_STRING) {
                parts.add(new action_part((String) tok.value));
                next();
            } else if (tok.sym == sym.BAR || tok.sym == sym.SEMI) {
                new production(lhs, (production_part[]) parts.toArray(new production_part[0]), parts.size());
                parts.clear();
                boolean end = tok.sym == sym.SEMI;
                next();
                if (end) return;
            } else throw new RuntimeException("unexpected token " + tok.sym + " in a production");
        }
    }
}
