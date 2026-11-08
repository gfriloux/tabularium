# Packages the owner chose: listed ones, those of enabled services, programs
# and virtualisation, and the kernel. Applied to a NixOS `config`; anything
# that throws while evaluating is dropped rather than failing the whole list.
config: let
  try = v: let
    r = builtins.tryEval v;
  in
    if r.success
    then r.value
    else null;

  # { name, version } of a derivation-like value, or null.
  describe = p: let
    parsed = builtins.parseDrvName (p.name or "");
    name = try (p.pname or parsed.name);
    version = try (p.version or parsed.version);
  in
    if builtins.isAttrs p && builtins.isString name && builtins.isString version && name != ""
    then {inherit name version;}
    else null;

  # Packages of the enabled modules of one namespace (services, programs…).
  enabled = ns: let
    modules = try (config.${ns} or {});
  in
    if builtins.isAttrs modules
    then
      builtins.concatMap (n: let
        m = try modules.${n};
      in
        if builtins.isAttrs m && try (m.enable or false) == true
        then [(try (m.package or null))]
        else []) (builtins.attrNames modules)
    else [];

  users = try (config.home-manager.users or {});
  homePackages =
    if builtins.isAttrs users
    then builtins.concatMap (u: try (users.${u}.home.packages or [])) (builtins.attrNames users)
    else [];

  candidates =
    (try (config.environment.systemPackages or []))
    ++ homePackages
    ++ enabled "services"
    ++ enabled "programs"
    ++ enabled "virtualisation"
    ++ [(try (config.boot.kernelPackages.kernel or null))];

  described = builtins.filter (d: d != null) (map (p:
    if p == null
    then null
    else try (describe p))
  candidates);

  # Unique by name, first occurrence wins, then sorted by name.
  unique = builtins.foldl' (acc: d:
    if builtins.any (x: x.name == d.name) acc
    then acc
    else acc ++ [d]) []
  described;
in
  builtins.sort (a: b: a.name < b.name) unique
