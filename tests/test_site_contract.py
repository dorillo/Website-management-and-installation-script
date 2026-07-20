from __future__ import annotations

import os
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SITE_ROOT = Path(
    os.environ.get("VPN_SITE_SOURCE", ROOT.parent / "vpn-site")
)


def assignment_keys(text: str) -> set[str]:
    return {
        line.split("=", 1)[0]
        for line in text.splitlines()
        if re.fullmatch(r"[A-Z][A-Z0-9_]*=.*", line)
    }


def assignments(text: str) -> dict[str, str]:
    return {
        line.split("=", 1)[0]: line.split("=", 1)[1]
        for line in text.splitlines()
        if re.fullmatch(r"[A-Z][A-Z0-9_]*=.*", line)
    }


def generated_environment_block() -> str:
    source = (ROOT / "lib" / "config.sh").read_text(encoding="utf-8")
    return source.split("# Managed by VPN Site Manager.", 1)[1].split(
        "\nEOF", 1
    )[0]


def normalize_nginx(text: str) -> str:
    return "\n".join(
        line.rstrip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )


class ManagerContractTests(unittest.TestCase):
    def test_removed_appearance_settings_are_not_generated(self) -> None:
        generated = assignment_keys(generated_environment_block())
        removed = {
            "PUBLIC_COPY_MODE",
            "PUBLIC_MODE_1_INN",
            "PUBLIC_MODE_2_INN",
            "BRAND_NAME",
            "SITE_TITLE",
            "SITE_TAGLINE",
            "LOGO_PATH",
            "FAVICON_PATH",
            "PUBLIC_NEUTRAL_SITE_TITLE",
            "PUBLIC_NEUTRAL_SITE_TAGLINE",
            "PUBLIC_NEUTRAL_LOGO_PATH",
            "PUBLIC_NEUTRAL_FAVICON_PATH",
        }
        self.assertTrue(generated.isdisjoint(removed))
        self.assertIn("SITE_NAME", generated)

    def test_current_frontend_environment_is_not_generated(self) -> None:
        deploy_source = (ROOT / "lib" / "deploy.sh").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("API_BASE_URL", deploy_source)
        self.assertNotIn("window.APP_ENV", deploy_source)

    def test_systemd_template_contains_current_safety_contract(self) -> None:
        service = (ROOT / "templates" / "vpn-site.service").read_text(
            encoding="utf-8"
        )
        self.assertIn(" -m alembic ", service)
        self.assertIn(" upgrade head\n", service)
        self.assertIn(" check\n", service)
        self.assertIn("--no-server-header --no-access-log", service)
        self.assertIn("TimeoutStartSec=300", service)
        self.assertIn("ProtectProc=invisible", service)
        self.assertIn("ProcSubset=pid", service)


@unittest.skipUnless(SITE_ROOT.is_dir(), "adjacent vpn-site checkout is absent")
class CrossRepositoryContractTests(unittest.TestCase):
    def test_generated_environment_matches_site_production_example(self) -> None:
        site_environment = (SITE_ROOT / ".env.example").read_text(
            encoding="utf-8"
        )
        self.assertEqual(
            assignment_keys(generated_environment_block()),
            assignment_keys(site_environment),
        )

        dynamic = {
            "ADMIN_BOOTSTRAP_EMAILS",
            "CORS_ALLOWED_ORIGINS",
            "DATABASE_URL",
            "FROM_EMAIL",
            "REMNAWAVE_API_URL",
            "REMNAWAVE_COOKIES_JSON",
            "REMNAWAVE_TOKEN",
            "SECRET_KEY",
            "SITE_NAME",
            "SMTP_HOST",
            "SMTP_PASSWORD",
            "SMTP_PORT",
            "SMTP_USER",
            "TRUSTED_HOSTS",
            "YOOKASSA_RETURN_URL",
            "YOOKASSA_SECRET_KEY",
            "YOOKASSA_SHOP_ID",
            "YOOKASSA_WEBHOOK_SECRET",
        }
        generated_values = assignments(generated_environment_block())
        site_values = assignments(site_environment)
        self.assertEqual(
            {k: v for k, v in generated_values.items() if k not in dynamic},
            {k: v for k, v in site_values.items() if k not in dynamic},
        )

    def test_nginx_semantics_match_site_template(self) -> None:
        manager = (ROOT / "templates" / "nginx.conf").read_text(
            encoding="utf-8"
        )
        before, remainder = manager.split("# __LEGACY_ENV_JS_BEGIN__", 1)
        _, after = remainder.split("# __LEGACY_ENV_JS_END__", 1)
        manager = before + after

        site = (
            SITE_ROOT / "deploy" / "nginx" / "vpn-site.conf.example"
        ).read_text(encoding="utf-8")
        site = site.replace("YOUR.PUBLIC.HOSTNAME", "__DOMAIN__")
        site = site.replace(
            "/opt/vpn-site/frontend",
            "/opt/vpn-site/current/frontend",
        )
        self.assertEqual(normalize_nginx(manager), normalize_nginx(site))

    def test_systemd_semantics_match_site_template(self) -> None:
        manager = (ROOT / "templates" / "vpn-site.service").read_text(
            encoding="utf-8"
        )
        site = (
            SITE_ROOT / "deploy" / "systemd" / "vpn-site.service"
        ).read_text(encoding="utf-8")
        site = site.replace("EnvironmentFile=/etc/vpn-site/vpn-site.env\n", "")
        site = site.replace("/opt/vpn-site/backend", "/opt/vpn-site/current/backend")
        site = site.replace("/opt/vpn-site/.venv", "/opt/vpn-site/current/.venv")
        site = site.replace(
            "/opt/vpn-site/alembic.ini",
            "/opt/vpn-site/current/alembic.ini",
        )
        envexec = (
            "/opt/vpn-site-manager/current/bin/envexec.py "
            "/etc/vpn-site/vpn-site.env "
        )
        site = re.sub(r"^(ExecStart(?:Pre)?=)", rf"\1{envexec}", site, flags=re.M)

        def normalize_unit(text: str) -> str:
            return "\n".join(
                line
                for line in text.splitlines()
                if line and not line.startswith("#") and not line.startswith("Description=")
            )

        self.assertEqual(normalize_unit(manager), normalize_unit(site))


if __name__ == "__main__":
    unittest.main()
