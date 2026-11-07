{
  pkgs,
  tabularium,
  seals,
  src,
}:
{
  nix = seals.nix src;
  gitleaks = seals.gitleaks src;
  markdown = seals.markdown {
    path = src;
    args = "-d MD013,MD033";
  };
}
// import ../tests/cli.nix {inherit pkgs tabularium;}
// import ../tests/record.nix {inherit pkgs;}
