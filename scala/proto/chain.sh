#!/usr/bin/env bash
# chain.sh [FROM]: (re)build stage1 and every stage in chain.txt starting at FROM
set -e
FROM=${1:-}
if [ -z "$FROM" ]; then
  /tmp/sc/work/stage-java.sh /tmp/sc/s1src /tmp/sc/st1 > /tmp/sc/log-st1.txt 2>&1
  J8=/nix/store/z2mxh5237w3dd8klbikm94x2wwipgc2y-openjdk-headless-8u504-b01
  cd /tmp/sc/st1; rm -rf lib2 sc2; mkdir lib2 sc2
  $J8/bin/java -Xss32m -cp scalac:lib:classes scala.tools.scalac.Main -d lib2 -classpath lib2:classes:src $(cat sfiles.txt) >> /tmp/sc/log-st1.txt 2>&1
  $J8/bin/java -Xss32m -cp scalac:lib:classes scala.tools.scalac.Main -d sc2 -classpath sc2:lib2:classes:src $(cat scfiles.txt) >> /tmp/sc/log-st1.txt 2>&1
  echo "st1 ok"
fi
go=${FROM:+0}; go=${go:-1}
grep -v '^#' /tmp/sc/work/chain.txt | while read name commit prev mode; do
  [ "$name" = "$FROM" ] && go=1
  [ $go = 1 ] || continue
  case $mode in
    normal) TAILN=20 /tmp/sc/work/try.sh $name $commit $( [ $prev = 1 ] && echo /tmp/sc/st1/sc2:/tmp/sc/st1/lib2:/tmp/sc/st1/classes || echo /tmp/sc/st-$prev/out2:/tmp/sc/st-$prev/classes ) | tail -3 ;;
    cf) COMPILER_FIRST=1 TAILN=20 /tmp/sc/work/try.sh $name $commit /tmp/sc/st-$prev/out2:/tmp/sc/st-$prev/classes | tail -3 ;;
    auto) /tmp/sc/work/auto.sh $name $commit $prev ;;
  esac
  grep -q 'stage done' /tmp/sc/log-$name.txt || { echo "$name FAILED"; exit 1; }
  echo "$name ok"
done
