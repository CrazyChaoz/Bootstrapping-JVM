package edu.umd.cs.findbugs.annotations;

import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;

/** Source-retention stand-in for SpotBugs' annotation (analysis only). */
@Retention(RetentionPolicy.CLASS)
public @interface SuppressFBWarnings {
  String[] value() default {};
  String justification() default "";
}
