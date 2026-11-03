# `regex-edit`: in-place regular expression edits of source files (see regex-edit.py), the
# multi-line counterpart of substituteInPlace.
{ runCommand, python3 }:

runCommand "regex-edit" { meta.mainProgram = "regex-edit"; } ''
  mkdir -p $out/bin
  { echo '#!${python3}/bin/python3 -I'; cat ${./regex-edit.py}; } > $out/bin/regex-edit
  chmod +x $out/bin/regex-edit
''
