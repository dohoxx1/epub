import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../models/epub_book.dart';

/// 캐시 디렉토리(이미 압축이 풀린 상태)를 읽어서 EpubBook 모델로 파싱한다.
/// EPUB2(OPF 2.0 + NCX)와 EPUB3(OPF 3.0 + NAV)를 모두 지원하되,
/// 우선순위는 EPUB2 → 실패 시 EPUB3 방식으로 폴백한다.
class EpubParserService {
  Future<EpubBook> parse({
    required String originalUri,
    required Directory cacheDir,
  }) async {
    // 1. container.xml에서 OPF 위치 찾기
    final containerFile =
        File(p.join(cacheDir.path, 'META-INF', 'container.xml'));
    final containerXml = XmlDocument.parse(await containerFile.readAsString());
    final rootfilePath = containerXml
        .findAllElements('rootfile')
        .first
        .getAttribute('full-path')!;

    final opfFile = File(p.join(cacheDir.path, rootfilePath));
    final opfDir = p.dirname(opfFile.path);
    final opfXml = XmlDocument.parse(await opfFile.readAsString());

    final packageEl = opfXml.findAllElements('package').first;
    final epubVersion = packageEl.getAttribute('version') ?? '2.0';

    // 2. 메타데이터 (title, author)
    final metadataEl = opfXml.findAllElements('metadata').first;
    final title = _firstText(metadataEl, 'title') ?? '(제목 없음)';
    final author = _firstText(metadataEl, 'creator');

    // 3. 매니페스트
    final manifestEl = opfXml.findAllElements('manifest').first;
    final manifest = <EpubManifestItem>[];
    for (final item in manifestEl.findElements('item')) {
      manifest.add(EpubManifestItem(
        id: item.getAttribute('id')!,
        href: item.getAttribute('href')!,
        mediaType: item.getAttribute('media-type') ?? '',
      ));
    }
    final manifestById = {for (final m in manifest) m.id: m};

    // 4. 스파인 (읽기 순서)
    final spineEl = opfXml.findAllElements('spine').first;
    final spine = <EpubSpineItem>[];
    for (final itemref in spineEl.findElements('itemref')) {
      final idref = itemref.getAttribute('idref')!;
      final manifestItem = manifestById[idref];
      if (manifestItem == null) continue; // 손상된 EPUB 방어
      final linear = itemref.getAttribute('linear') != 'no';
      spine.add(EpubSpineItem(
        idref: idref,
        href: p.normalize(p.join(opfDir, manifestItem.href)),
        linear: linear,
      ));
    }

    // 5. 표지 이미지 (메타데이터 cover 참조 우선, 없으면 manifest에서 cover-image 속성 탐색)
    String? coverPath = _resolveCoverPath(metadataEl, manifestById, opfDir);

    // 6. 목차: EPUB3는 nav 문서, EPUB2는 NCX. 둘 다 시도해서 있는 쪽을 사용.
    List<EpubTocNode> toc = [];
    final navItem = manifest
        .where((m) => m.mediaType == 'application/xhtml+xml')
        .where((m) => _isNavItem(manifestEl, m.id))
        .toList();
    if (navItem.isNotEmpty) {
      final navFile = File(p.normalize(p.join(opfDir, navItem.first.href)));
      if (await navFile.exists()) {
        toc =
            _parseNavToc(await navFile.readAsString(), p.dirname(navFile.path));
      }
    }
    if (toc.isEmpty) {
      final ncxId = spineEl.getAttribute('toc');
      final ncxItem = ncxId != null ? manifestById[ncxId] : null;
      if (ncxItem != null) {
        final ncxFile = File(p.normalize(p.join(opfDir, ncxItem.href)));
        if (await ncxFile.exists()) {
          toc = _parseNcxToc(
              await ncxFile.readAsString(), p.dirname(ncxFile.path));
        }
      }
    }

    return EpubBook(
      originalUri: originalUri,
      cacheDir: cacheDir.path,
      opfPath: opfFile.path,
      title: title,
      author: author,
      coverImagePath: coverPath,
      epubVersion: epubVersion,
      manifest: manifest,
      spine: spine,
      toc: toc,
    );
  }

  String? _firstText(XmlElement metadataEl, String localName) {
    final matches =
        metadataEl.findElements(localName, namespace: '*').isNotEmpty
            ? metadataEl.findElements(localName, namespace: '*')
            : metadataEl.children
                .whereType<XmlElement>()
                .where((e) => e.name.local == localName);
    for (final el in matches) {
      final text = el.innerText.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  bool _isNavItem(XmlElement manifestEl, String id) {
    for (final item in manifestEl.findElements('item')) {
      if (item.getAttribute('id') == id) {
        final props = item.getAttribute('properties') ?? '';
        return props.split(' ').contains('nav');
      }
    }
    return false;
  }

  String? _resolveCoverPath(XmlElement metadataEl,
      Map<String, EpubManifestItem> manifestById, String opfDir) {
    // EPUB2: <meta name="cover" content="cover-image-id"/>
    for (final meta in metadataEl.findElements('meta')) {
      if (meta.getAttribute('name') == 'cover') {
        final id = meta.getAttribute('content');
        final item = id != null ? manifestById[id] : null;
        if (item != null) return p.normalize(p.join(opfDir, item.href));
      }
    }
    // EPUB3 fallback: manifest item에 properties="cover-image"
    for (final item in manifestById.values) {
      if (item.mediaType.startsWith('image/')) {
        // properties 속성은 EpubManifestItem에 없으므로 간단 휴리스틱: 파일명에 cover 포함
        if (item.href.toLowerCase().contains('cover')) {
          return p.normalize(p.join(opfDir, item.href));
        }
      }
    }
    return null;
  }

  /// EPUB3 nav.xhtml 안의 <nav epub:type="toc"> ... <ol><li> 구조 파싱
  List<EpubTocNode> _parseNavToc(String xhtml, String navDir) {
    final doc = XmlDocument.parse(xhtml);
    final navEls = doc.findAllElements('nav');
    XmlElement? tocNav;
    for (final nav in navEls) {
      final type = nav.getAttribute('epub:type') ?? nav.getAttribute('type');
      if (type == 'toc' || tocNav == null) tocNav = nav;
      if (type == 'toc') break;
    }
    if (tocNav == null) return [];
    final ol = tocNav.findElements('ol').isNotEmpty
        ? tocNav.findElements('ol').first
        : null;
    if (ol == null) return [];
    return _parseNavList(ol, navDir);
  }

  List<EpubTocNode> _parseNavList(XmlElement ol, String baseDir) {
    final nodes = <EpubTocNode>[];
    for (final li in ol.findElements('li')) {
      final a =
          li.findElements('a').isNotEmpty ? li.findElements('a').first : null;
      if (a == null) continue;
      final title = a.innerText.trim();
      final href = a.getAttribute('href') ?? '';
      final childOl =
          li.findElements('ol').isNotEmpty ? li.findElements('ol').first : null;
      nodes.add(EpubTocNode(
        title: title,
        href: p.normalize(p.join(baseDir, href)),
        children: childOl != null ? _parseNavList(childOl, baseDir) : [],
      ));
    }
    return nodes;
  }

  /// EPUB2 toc.ncx의 <navMap><navPoint> 구조 파싱
  List<EpubTocNode> _parseNcxToc(String ncx, String ncxDir) {
    final doc = XmlDocument.parse(ncx);
    final navMap = doc.findAllElements('navMap');
    if (navMap.isEmpty) return [];
    return _parseNavPoints(navMap.first, ncxDir);
  }

  List<EpubTocNode> _parseNavPoints(XmlElement parent, String baseDir) {
    final nodes = <EpubTocNode>[];
    for (final navPoint in parent.findElements('navPoint')) {
      final labelEl = navPoint.findAllElements('text').isNotEmpty
          ? navPoint.findAllElements('text').first
          : null;
      final title = labelEl?.innerText.trim() ?? '';
      final contentEl = navPoint.findElements('content').isNotEmpty
          ? navPoint.findElements('content').first
          : null;
      final src = contentEl?.getAttribute('src') ?? '';
      nodes.add(EpubTocNode(
        title: title,
        href: p.normalize(p.join(baseDir, src)),
        children: _parseNavPoints(navPoint, baseDir),
      ));
    }
    return nodes;
  }
}
