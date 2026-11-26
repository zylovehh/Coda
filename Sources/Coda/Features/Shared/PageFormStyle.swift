import SwiftUI

extension View {
    /// Grouped forms shown in the main content column (settings and its
    /// pages) share the page canvas with every other page. On macOS the
    /// system grouped form caps its width, so a full-width equivalent is used.
    func pageFormStyle() -> some View {
        modifier(PageFormStyleModifier())
    }

    /// Rows need their own fill once the grouped backdrop is gone: iPad pages
    /// use the plain system background, which matches the default row fill.
    /// Apply to the Form's content (rows inherit it through sections).
    func pageFormRows() -> some View {
        modifier(PageFormRows())
    }

    /// Navigation rows inside a page form: native list rows on iOS, a
    /// full-width row with a disclosure chevron on macOS.
    func pageFormNavigationRow() -> some View {
        #if os(macOS)
        buttonStyle(PageFormNavigationRowStyle())
        #else
        self
        #endif
    }
}

private struct PageFormRows: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.listRowBackground(Color(uiColor: .secondarySystemBackground))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct PageFormStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        } else {
            content.formStyle(.grouped)
        }
        #else
        content.formStyle(PageGroupedFormStyle())
        #endif
    }
}

#if os(macOS)
/// Full-width grouped form: headers, rounded cards with separated rows and
/// footers, matching the native grouped form without its maximum width.
private struct PageGroupedFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections: configuration.content) { section in
                    PageFormSection(section: section)
                }
                PlayerClearanceSpacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(PageFormToggleStyle())
        .labelStyle(PageFormLabelStyle())
        .labeledContentStyle(PageFormLabeledContentStyle())
        // The native grouped form draws menus as plain rows, not pop-up buttons.
        .menuStyle(.borderlessButton)
    }
}

private struct PageFormSection: View {
    let section: SectionConfiguration
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.header.isEmpty {
                VStack(alignment: .leading) { section.header }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
            }
            if !section.content.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.content) { row in
                        row
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        if row.id != section.content.last?.id {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
                .background(Theme.cardBackground(colorScheme),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
                }
            }
            if !section.footer.isEmpty {
                VStack(alignment: .leading) { section.footer }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// Symbols differ in width; a fixed icon column keeps row titles aligned.
private struct PageFormLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 20, alignment: .center)
            configuration.title
        }
    }
}

/// Label leading, switch trailing — the grouped form's toggle layout.
private struct PageFormToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center) {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
                .labelsHidden()
        }
    }
}

private struct PageFormLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct PageFormNavigationRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
#endif
