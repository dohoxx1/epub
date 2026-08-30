/// EPUB 매니페스트의 리소스 하나 (챕터 HTML, 이미지, CSS, 폰트 등)
class EpubManifestItem {
  final String id;
  final String href; // OPF 파일 기준 상대 경로
  final String mediaType;

  EpubManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
  });
}

/// 스파인(읽는 순서) 항목 하나 = 챕터 1개
class EpubSpineItem {
  final String idref; // manifest의 id를 참조
  final String href; // 실제 파일 경로 (캐시 디렉토리 기준 절대 경로)
  final bool linear;

  EpubSpineItem({
    required this.idref,
    required this.href,
    this.linear = true,
  });
}

/// 목차(TOC) 트리 노드. EPUB2(NCX)와 EPUB3(NAV)를 동일한 구조로 흡수한다.
class EpubTocNode {
  final String title;
  final String href; // 캐시 디렉토리 기준 경로 (# 앵커 포함 가능)
  final List<EpubTocNode> children;

  EpubTocNode({
    required this.title,
    required this.href,
    List<EpubTocNode>? children,
  }) : children = children ?? [];
}

/// 파싱이 끝난 EPUB 한 권을 나타내는 모델.
/// 원본 파일은 절대 건드리지 않고, 압축 해제된 캐시 디렉토리 경로만 들고 있는다.
class EpubBook {
  final String originalUri; // 원본 파일의 SAF URI 혹은 절대 경로 (이동/복사 안 함)
  final String cacheDir; // 압축이 풀린 임시/캐시 디렉토리 (앱 전용 저장소)
  final String opfPath; // 캐시 디렉토리 기준 OPF 절대 경로

  final String title;
  final String? author;
  final String? coverImagePath; // 캐시 디렉토리 기준 절대 경로

  final String epubVersion; // "2.0" / "3.0" 등

  final List<EpubManifestItem> manifest;
  final List<EpubSpineItem> spine;
  final List<EpubTocNode> toc;

  EpubBook({
    required this.originalUri,
    required this.cacheDir,
    required this.opfPath,
    required this.title,
    this.author,
    this.coverImagePath,
    required this.epubVersion,
    required this.manifest,
    required this.spine,
    required this.toc,
  });
}
