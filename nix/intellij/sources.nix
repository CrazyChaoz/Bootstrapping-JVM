{ fetchIntellij }:
{
  # TarCV uses this commit for "139"
  "139" = fetchIntellij {
    rev = "26e72feacf91bfb222bec00b3139ed05aa3084b5";
    hash = "sha256-gwAGVMx9Mo6ae6zD858YHSgDNSzj2ix/zSANNcclE6U=";
  };
  "141" = fetchIntellij {
    rev = "refs/heads/141";
    hash = "sha256-uYkDQwEhIwoMX4v6QwXkuEw1QDtm2pJACgdodQ+HGWY=";
  };
  "143" = fetchIntellij {
    rev = "refs/heads/143";
    hash = "sha256-31OgfrewOK7k229jqHmhjhpTfONRQxnwaieWx4wYM7Y=";
  };
  "172" = fetchIntellij {
    rev = "refs/heads/172";
    hash = "sha256-4wZQe7HQJluM/2VYxbkUIQzsvND996SMx9mUMFTIzd8=";
  };
  "173" = fetchIntellij {
    rev = "refs/heads/173";
    hash = "sha256-RI5v5/9Zq10zs+toDPvJhtz/dDXaJz99PqGr5ddPQkY=";
  };
  "181" = fetchIntellij {
    rev = "refs/heads/181";
    hash = "sha256-pLs+965MqIvn2uhqpzP+xBde8OUOmh+RNg+kyptN9Tg=";
  };
}
