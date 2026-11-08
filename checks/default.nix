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
// import ../tests/last.nix {inherit pkgs;}
// import ../tests/freshness.nix {inherit pkgs;}
// import ../tests/sbom.nix {inherit pkgs;}
// import ../tests/important.nix {inherit pkgs;}
// import ../tests/cve-diff.nix {inherit pkgs;}
// import ../tests/cve.nix {inherit pkgs;}
