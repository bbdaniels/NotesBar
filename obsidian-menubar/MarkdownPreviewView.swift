import SwiftUI
import AppKit
import WebKit

struct MarkdownPreviewView: View {
    let file: NoteFile
    var onTap: (() -> Void)? = nil
    @State private var content: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header with file name
            HStack {
                Text(file.name.replacingOccurrences(of: ".md", with: ""))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap?()
            }

            Divider()

            // Content area - WebKit preview
            MarkdownWebView(content: content, filePath: file.path)
                .frame(width: 450, height: 400)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .onAppear {
            loadContent()
        }
    }

    private func loadContent() {
        let fileURL = URL(fileURLWithPath: file.path)
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
            content = content.replacingOccurrences(of: "\r\n", with: "\n")
        } catch {
            content = "Error loading content: \(error.localizedDescription)"
        }
    }
}

/// NSViewRepresentable wrapper for WKWebView to render markdown as HTML
struct MarkdownWebView: NSViewRepresentable {
    let content: String
    let filePath: String
    var onContentChanged: ((String) -> Void)?
    var searchText: String = ""
    var onSearchResultsChanged: ((Int, Int) -> Void)? // (currentIndex, totalMatches)

    init(content: String, filePath: String, onContentChanged: ((String) -> Void)? = nil) {
        self.content = content
        self.filePath = filePath
        self.onContentChanged = onContentChanged
    }

    init(content: String, filePath: String, searchText: String, onContentChanged: ((String) -> Void)? = nil, onSearchResultsChanged: ((Int, Int) -> Void)? = nil) {
        self.content = content
        self.filePath = filePath
        self.searchText = searchText
        self.onContentChanged = onContentChanged
        self.onSearchResultsChanged = onSearchResultsChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Add message handler for checkbox toggles
        config.userContentController.add(context.coordinator, name: "checkboxToggle")
        // Add message handler for search results
        config.userContentController.add(context.coordinator, name: "searchResults")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        // Check if content changed (need to reload HTML)
        let html = MarkdownStyler.createStyledHTML(from: content)
        let contentHash = content.hashValue

        if context.coordinator.lastContentHash != contentHash {
            context.coordinator.lastContentHash = contentHash
            webView.loadHTMLString(html, baseURL: nil)
            // Re-apply search after content loads
            if !searchText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    context.coordinator.performSearch(searchText)
                }
            }
        } else if context.coordinator.lastSearchText != searchText {
            // Only search text changed
            context.coordinator.lastSearchText = searchText
            context.coordinator.performSearch(searchText)
        }
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MarkdownWebView
        weak var webView: WKWebView?
        var lastContentHash: Int = 0
        var lastSearchText: String = ""

        init(_ parent: MarkdownWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "checkboxToggle",
               let body = message.body as? [String: Any],
               let lineNumber = body["line"] as? Int,
               let isChecked = body["checked"] as? Bool {
                toggleCheckboxInFile(at: lineNumber, checked: isChecked)
            } else if message.name == "searchResults",
                      let body = message.body as? [String: Any],
                      let current = body["current"] as? Int,
                      let total = body["total"] as? Int {
                parent.onSearchResultsChanged?(current, total)
            }
        }

        func performSearch(_ text: String) {
            guard let webView = webView else { return }

            if text.isEmpty {
                // Clear highlights
                let clearJS = "window.clearSearchHighlights && window.clearSearchHighlights();"
                webView.evaluateJavaScript(clearJS, completionHandler: nil)
                parent.onSearchResultsChanged?(0, 0)
                return
            }

            // JavaScript for find and highlight
            let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")

            let searchJS = """
            (function() {
                // Clear previous highlights first
                if (window.clearSearchHighlights) {
                    window.clearSearchHighlights();
                }

                var searchText = '\(escapedText)'.toLowerCase();
                if (!searchText) {
                    window.webkit.messageHandlers.searchResults.postMessage({current: 0, total: 0});
                    return;
                }

                var matches = [];

                // Find all text nodes
                var walker = document.createTreeWalker(
                    document.body,
                    NodeFilter.SHOW_TEXT,
                    null,
                    false
                );

                var nodesToHighlight = [];
                var node;
                while (node = walker.nextNode()) {
                    var text = node.nodeValue;
                    var lowerText = text.toLowerCase();
                    var index = 0;
                    while ((index = lowerText.indexOf(searchText, index)) !== -1) {
                        nodesToHighlight.push({node: node, start: index, length: searchText.length});
                        index += searchText.length;
                    }
                }

                // Highlight matches (in reverse order to preserve indices)
                for (var i = nodesToHighlight.length - 1; i >= 0; i--) {
                    var item = nodesToHighlight[i];
                    try {
                        var range = document.createRange();
                        range.setStart(item.node, item.start);
                        range.setEnd(item.node, item.start + item.length);

                        var span = document.createElement('span');
                        span.className = 'search-highlight';
                        span.style.cssText = 'background-color: #ffeb3b !important; color: #000 !important; border-radius: 2px; padding: 1px 0;';
                        range.surroundContents(span);
                        matches.unshift(span);
                    } catch (e) {
                        // Skip nodes that can't be highlighted (e.g., crossing element boundaries)
                        console.log('Skip highlight:', e);
                    }
                }

                window.searchMatches = matches;
                window.currentMatchIndex = 0;

                // Highlight first match as current and scroll to it
                if (matches.length > 0) {
                    matches[0].style.cssText = 'background-color: #ff9800 !important; color: #000 !important; border-radius: 2px; padding: 1px 0;';
                    setTimeout(function() {
                        matches[0].scrollIntoView({behavior: 'smooth', block: 'center'});
                    }, 50);
                }

                window.webkit.messageHandlers.searchResults.postMessage({
                    current: matches.length > 0 ? 1 : 0,
                    total: matches.length
                });

                // Define navigation functions
                window.nextMatch = function() {
                    if (!window.searchMatches || window.searchMatches.length === 0) return;
                    window.searchMatches[window.currentMatchIndex].style.cssText = 'background-color: #ffeb3b !important; color: #000 !important; border-radius: 2px; padding: 1px 0;';
                    window.currentMatchIndex = (window.currentMatchIndex + 1) % window.searchMatches.length;
                    window.searchMatches[window.currentMatchIndex].style.cssText = 'background-color: #ff9800 !important; color: #000 !important; border-radius: 2px; padding: 1px 0;';
                    window.searchMatches[window.currentMatchIndex].scrollIntoView({behavior: 'smooth', block: 'center'});
                    window.webkit.messageHandlers.searchResults.postMessage({
                        current: window.currentMatchIndex + 1,
                        total: window.searchMatches.length
                    });
                };

                window.previousMatch = function() {
                    if (!window.searchMatches || window.searchMatches.length === 0) return;
                    window.searchMatches[window.currentMatchIndex].style.cssText = 'background-color: #ffeb3b !important; color: #000 !important; border-radius: 2px; padding: 1px 0;';
                    window.currentMatchIndex = (window.currentMatchIndex - 1 + window.searchMatches.length) % window.searchMatches.length;
                    window.searchMatches[window.currentMatchIndex].style.cssText = 'background-color: #ff9800 !important; color: #000 !important; border-radius: 2px; padding: 1px 0;';
                    window.searchMatches[window.currentMatchIndex].scrollIntoView({behavior: 'smooth', block: 'center'});
                    window.webkit.messageHandlers.searchResults.postMessage({
                        current: window.currentMatchIndex + 1,
                        total: window.searchMatches.length
                    });
                };

                window.clearSearchHighlights = function() {
                    var highlights = document.querySelectorAll('.search-highlight');
                    highlights.forEach(function(span) {
                        var parentNode = span.parentNode;
                        if (parentNode) {
                            while (span.firstChild) {
                                parentNode.insertBefore(span.firstChild, span);
                            }
                            parentNode.removeChild(span);
                            parentNode.normalize();
                        }
                    });
                    window.searchMatches = [];
                    window.currentMatchIndex = 0;
                };
            })();
            """

            webView.evaluateJavaScript(searchJS, completionHandler: nil)
        }

        func nextMatch() {
            webView?.evaluateJavaScript("window.nextMatch && window.nextMatch();", completionHandler: nil)
        }

        func previousMatch() {
            webView?.evaluateJavaScript("window.previousMatch && window.previousMatch();", completionHandler: nil)
        }

        private func toggleCheckboxInFile(at lineNumber: Int, checked: Bool) {
            let fileURL = URL(fileURLWithPath: parent.filePath)

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return
            }

            var lines = content.components(separatedBy: "\n")

            guard lineNumber < lines.count else { return }

            let line = lines[lineNumber]

            // Replace checkbox state
            var newLine = line
            if checked {
                // Change [ ] to [x]
                newLine = line.replacingOccurrences(of: "[ ]", with: "[x]")
            } else {
                // Change [x] or [X] to [ ]
                newLine = line.replacingOccurrences(of: "[x]", with: "[ ]")
                newLine = newLine.replacingOccurrences(of: "[X]", with: "[ ]")
            }

            lines[lineNumber] = newLine
            let newContent = lines.joined(separator: "\n")

            // Save the file
            try? newContent.write(to: fileURL, atomically: true, encoding: .utf8)

            // Notify parent of content change
            parent.onContentChanged?(newContent)
        }
    }
}

/// A wrapper view that adds search functionality to MarkdownWebView
struct SearchableMarkdownWebView: View {
    let content: String
    let filePath: String
    var onContentChanged: ((String) -> Void)?

    @Binding var isSearchVisible: Bool
    @State private var searchText: String = ""
    @State private var currentMatch: Int = 0
    @State private var totalMatches: Int = 0
    @State private var coordinatorRef: MarkdownWebView.Coordinator?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            if isSearchVisible {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))

                    TextField("Find in document...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($isSearchFieldFocused)
                        .onSubmit {
                            coordinatorRef?.nextMatch()
                        }

                    if totalMatches > 0 {
                        Text("\(currentMatch)/\(totalMatches)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    } else if !searchText.isEmpty {
                        Text("No matches")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Button(action: { coordinatorRef?.previousMatch() }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(totalMatches == 0)

                    Button(action: { coordinatorRef?.nextMatch() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(totalMatches == 0)

                    Button(action: {
                        searchText = ""
                        isSearchVisible = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Divider()
            }

            // WebView with search support
            SearchableMarkdownWebViewRepresentable(
                content: content,
                filePath: filePath,
                searchText: searchText,
                onContentChanged: onContentChanged,
                onSearchResultsChanged: { current, total in
                    currentMatch = current
                    totalMatches = total
                },
                coordinatorRef: $coordinatorRef
            )
        }
        .onChange(of: isSearchVisible) { _, visible in
            if visible {
                // Delay focus to ensure TextField is rendered
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFieldFocused = true
                }
            } else {
                searchText = ""
            }
        }
    }
}

/// NSViewRepresentable that exposes the coordinator for search navigation
struct SearchableMarkdownWebViewRepresentable: NSViewRepresentable {
    let content: String
    let filePath: String
    let searchText: String
    var onContentChanged: ((String) -> Void)?
    var onSearchResultsChanged: ((Int, Int) -> Void)?
    @Binding var coordinatorRef: MarkdownWebView.Coordinator?

    func makeCoordinator() -> MarkdownWebView.Coordinator {
        let parent = MarkdownWebView(
            content: content,
            filePath: filePath,
            searchText: searchText,
            onContentChanged: onContentChanged,
            onSearchResultsChanged: onSearchResultsChanged
        )
        return MarkdownWebView.Coordinator(parent)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(context.coordinator, name: "checkboxToggle")
        config.userContentController.add(context.coordinator, name: "searchResults")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        DispatchQueue.main.async {
            coordinatorRef = context.coordinator
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update parent reference with current values
        context.coordinator.parent = MarkdownWebView(
            content: content,
            filePath: filePath,
            searchText: searchText,
            onContentChanged: onContentChanged,
            onSearchResultsChanged: onSearchResultsChanged
        )

        let html = MarkdownStyler.createStyledHTML(from: content)
        let contentHash = content.hashValue

        if context.coordinator.lastContentHash != contentHash {
            context.coordinator.lastContentHash = contentHash
            webView.loadHTMLString(html, baseURL: nil)
            if !searchText.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    context.coordinator.performSearch(searchText)
                }
            }
        } else if context.coordinator.lastSearchText != searchText {
            context.coordinator.lastSearchText = searchText
            context.coordinator.performSearch(searchText)
        }
    }
}

#Preview {
    MarkdownPreviewView(file: NoteFile(
        name: "test.md",
        path: "/path/to/test.md",
        relativePath: "test.md",
        isDirectory: false,
        children: nil
    ))
}
