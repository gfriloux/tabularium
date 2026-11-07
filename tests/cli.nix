{
  pkgs,
  tabularium,
}: {
  cli_usage = pkgs.runCommand "tabularium-cli-usage" {nativeBuildInputs = [tabularium];} ''
    set +e
    tabularium >out 2>&1
    code=$?
    set -e
    test "$code" -eq 64
    grep -q 'usage: tabularium' out
    tabularium nope >/dev/null 2>&1 && exit 1 || test $? -eq 64
    touch $out
  '';
}
