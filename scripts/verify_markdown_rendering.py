"""Run the shared Markdown semantics tests with macOS Foundation before app builds."""
from pathlib import Path
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="scribe-markdown-") as temporary:
        root = Path(temporary)
        source = root / "Sources" / "ScribeMarkdownCheck"
        tests = root / "Tests" / "ScribeMarkdownCheckTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ScribeMarkdownCheck", platforms: [.macOS(.v12)], targets: [
    .target(name: "ScribeMarkdownCheck"),
    .testTarget(name: "ScribeMarkdownCheckTests", dependencies: ["ScribeMarkdownCheck"])
])
''')
        (source / "ScribeMarkdownDocument.swift").write_text(
            (repo / "shared/ScribeMarkdownDocument.swift").read_text(encoding="utf-8"), encoding="utf-8")
        (tests / "MarkdownRenderingTests.swift").write_text(
            (repo / "native-tests/MarkdownRenderingTests.swift").read_text(encoding="utf-8").replace(
                "@testable import ScribePilot", "@testable import ScribeMarkdownCheck"), encoding="utf-8")
        subprocess.run(["swift", "test", "--package-path", str(root)], check=True)


if __name__ == "__main__":
    main()
