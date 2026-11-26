// Adapted from MeloX's PlaylistDetailContent.swift at
// 9c2f87b57b54ddbab76a4a53736f4840719a0947 (GPL-3.0-only).
// Copyright MeloX contributors. See ThirdPartyNotices/MeloX.md.
import SwiftUI

/// Shared collection header: search above the hero on both iPhone and iPad.
struct PlaylistHeader<Actions: View>: View {
    var phoneLayout = PhonePageLayout()
    private var usesWideDetailHeader: Bool { !phoneLayout.isEnabled }
    let artworkURL: String?
    let title: String
    let subtitle: String
    let avatarURL: String?
    let metadataText: String
    @Binding var filter: String
    @Binding var searchFocused: Bool
    var searchPlaceholder: String = String(localized: "在歌单中搜索")
    var isLoading = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        if usesWideDetailHeader {
            IPadDetailHeader(artworkURL: artworkURL, title: title,
                                 subtitle: subtitle, avatarURL: avatarURL,
                                 metadataText: metadataText, searchText: $filter,
                                 searchFocused: $searchFocused, searchPlaceholder: searchPlaceholder,
                                 isLoading: isLoading, actions: actions)
        } else {
            VStack(spacing: 0) {
                // Search is static page chrome. Keep its actual geometry rather
                // than presenting it as the first, cover-like skeleton block.
                PlaylistSearchBar(text: $filter, isFocused: $searchFocused,
                                      placeholder: searchPlaceholder)
                    .disabled(isLoading)
                .padding(.horizontal, phoneLayout.contentInset)
                .padding(.top, Theme.Spacing.small)

                PlaylistDetailHero(artworkURL: artworkURL, title: title,
                                       subtitle: subtitle, avatarURL: avatarURL,
                                       metadataText: metadataText, isLoading: isLoading, actions: actions)
            }
        }
    }

}

/// The same search surface above phone heroes and iPad detail headers.
struct PlaylistSearchBar: View {
    @ScaledMetric(relativeTo: .body) private var controlHeight = Theme.Layout.controlHeight
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String = String(localized: "在歌单中搜索")

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
            PlaylistInlineSearchField(text: $text, isFocused: $isFocused,
                                      placeholder: placeholder)
        }
        .padding(.horizontal, Theme.Spacing.component)
        // A UIKit text field can accept extra vertical space from the
        // scroll header. Give the capsule a concrete control height.
        .frame(height: controlHeight)
        .compatGlass(interactive: true, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playlistSearchBar")
    }
}

/// Collection header with the author avatar and actions.
struct PlaylistDetailHero<Actions: View>: View {
    var phoneLayout = PhonePageLayout()
    private var usesWideDetailHeader: Bool { !phoneLayout.isEnabled }
    let artworkURL: String?
    let title: String
    let subtitle: String
    let avatarURL: String?
    let metadataText: String
    var circularArtwork = false
    var showsAvatar = true
    /// The "我的" page hides the big profile picture; playlist and artist
    /// pages keep it.
    var showsArtwork = true
    var isLoading = false
    @ViewBuilder var actions: () -> Actions

    @State private var availableWidth: CGFloat = 320
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 26
    @ScaledMetric(relativeTo: .title3) private var subtitleLineHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var metadataLineHeight: CGFloat = 18

    var body: some View {
        if usesWideDetailHeader {
            IPadDetailHeader(artworkURL: artworkURL, title: title,
                                 subtitle: subtitle, avatarURL: avatarURL,
                                 metadataText: metadataText, circularArtwork: circularArtwork,
                                 showsAvatar: showsAvatar, showsArtwork: showsArtwork,
                                 isLoading: isLoading, actions: actions)
        } else {
            phoneHero
        }
    }

    private var phoneHero: some View {
        VStack(spacing: 0) {
            if showsArtwork {
                artwork
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                    .accessibilityHidden(true)
            }

            Group {
                if isLoading {
                    SkeletonView(cornerRadius: 4)
                        .frame(width: min(availableWidth - 48, 220), height: titleLineHeight)
                } else {
                    Text(title)
                        .font(Theme.Typography.detailTitle)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .padding(.top, showsArtwork ? Theme.Spacing.page : 0)
            .padding(.horizontal, phoneLayout.contentInset)

            HStack(spacing: Theme.Spacing.small) {
                if showsAvatar {
                    Group {
                        if isLoading {
                            SkeletonView(cornerRadius: 12)
                        } else {
                            CachedAsyncImage(url: avatarURL?.resizedImageURL(80), animated: false) {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                }
                if isLoading {
                    SkeletonView(cornerRadius: 4).frame(width: 112, height: subtitleLineHeight)
                } else {
                    Text(subtitle)
                        .font(Theme.Typography.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, Theme.Spacing.small)
            .padding(.horizontal, phoneLayout.contentInset)

            Group {
                if isLoading {
                    SkeletonView(cornerRadius: 4).frame(width: 180, height: metadataLineHeight)
                } else {
                    Text(metadataText)
                        .font(Theme.Typography.secondary.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.top, Theme.Spacing.small)
            .padding(.horizontal, phoneLayout.contentInset)

            actions()
                .padding(.top, Theme.Spacing.component)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, showsArtwork ? Theme.Spacing.section : Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.section)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { availableWidth = $0 }
            }
        }
    }

    private var artwork: some View {
        let size = min(availableWidth * 0.68, 300)
        return Group {
            if isLoading {
                // Size the skeleton itself, independently of an empty image's proposal.
                SkeletonView(cornerRadius: circularArtwork ? size / 2 : 12)
            } else {
                CachedAsyncImage(url: artworkURL?.resizedImageURL(1536), animated: false)
            }
        }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: circularArtwork ? size / 2 : 12,
                                        style: .continuous))
    }
}

/// One tablet layout for every collection/profile hero. Page callers supply
/// content and actions; search placement and bottom alignment live here.
private struct IPadDetailHeader<Actions: View>: View {
    let artworkURL: String?
    let title: String
    let subtitle: String
    let avatarURL: String?
    let metadataText: String
    var circularArtwork = false
    var showsAvatar = true
    var showsArtwork = true
    var searchText: Binding<String>? = nil
    var searchFocused: Binding<Bool>? = nil
    var searchPlaceholder: String = String(localized: "在歌单中搜索")
    var isLoading = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        MusicLibraryHeaderLayout(title: title, icon: nil, coverURL: artworkURL,
                                 circularCover: circularArtwork, showsCover: showsArtwork,
                                 isLoading: isLoading, usesPlaylistActions: true,
                                 searchText: searchText, searchFocused: searchFocused,
                                 searchPlaceholder: searchPlaceholder) {
            EmptyView()
        } metadata: {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    if showsAvatar, let avatarURL {
                        CachedAsyncImage(url: avatarURL.resizedImageURL(80), animated: false)
                            .frame(width: 24, height: 24)
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                    }
                    Text(subtitle)
                        .font(Theme.Typography.secondary)
                        .lineLimit(2)
                }
                Text(metadataText)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            actions()
        }
    }
}

private enum PlaylistActionMetrics {
    static let height = Theme.Layout.detailActionHeight
}

/// Three-button action row with playlist subscription.
struct PlaylistPrimaryActions<More: View>: View {
    var phoneLayout = PhonePageLayout()
    private var usesWideDetailHeader: Bool { !phoneLayout.isEnabled }
    let isSaved: Bool
    let canSave: Bool
    let canPlay: Bool
    let isSaving: Bool
    let onToggleSaved: () -> Void
    let onPlayAll: () -> Void
    var leadingIcon: String? = nil
    var primaryTitle: LocalizedStringKey = "播放"
    var primaryIcon: String? = "play.fill"
    var showsSaveButton = true
    var saveAccessibilityLabel: String? = nil
    var saveAccessibilityIdentifier = "playlistSubscribe"
    var horizontalPadding: CGFloat? = nil
    @ViewBuilder var more: () -> More

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.control) {
            if showsSaveButton {
                Button(action: onToggleSaved) {
                    Group {
                        if let leadingIcon {
                            Image(systemName: leadingIcon)
                        } else {
                            CollectionStarIcon(isSelected: isSaved)
                        }
                    }
                        .font(.title2.weight(.semibold))
                        .frame(width: PlaylistActionMetrics.height, height: PlaylistActionMetrics.height)
                        .compatGlass(interactive: true, in: Circle())
                        // The legacy glass background does not participate in hit testing.
                        // Make the entire visible control tappable, including empty icon space.
                        .contentShape(Circle())
                }
                .disabled(!canSave || isSaving)
                .accessibilityLabel(saveAccessibilityLabel
                    ?? (isSaved ? String(localized: "取消收藏歌单") : String(localized: "收藏歌单")))
                .accessibilityIdentifier(saveAccessibilityIdentifier)
            }

            Button(action: onPlayAll) {
                Group {
                    if let primaryIcon {
                        Label(primaryTitle, systemImage: primaryIcon)
                    } else {
                        Text(primaryTitle)
                    }
                }
                    .font(Theme.Typography.cardTitle)
                    .frame(minWidth: 116, maxWidth: .infinity)
                    .frame(height: PlaylistActionMetrics.height)
                    .foregroundStyle(colorScheme == .dark ? .black : .white)
                    .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
            }
            .disabled(!canPlay)

            more()
                #if os(macOS)
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                #endif
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(maxWidth: 328)
        .padding(.horizontal, horizontalPadding ?? (usesWideDetailHeader ? 0 : phoneLayout.contentInset))
    }
}

struct PlaylistMoreLabel: View {
    var icon = "ellipsis"

    var body: some View {
        Image(systemName: icon)
            .font(.title2.weight(.semibold))
            .frame(width: PlaylistActionMetrics.height, height: PlaylistActionMetrics.height)
            #if os(macOS)
            // Let Menu own mouse tracking across the whole visible control.
            // An interactive glass label can capture clicks before NSMenu does.
            .compatGlass(in: Circle())
            .contentShape(Rectangle())
            #else
            .compatGlass(interactive: true, in: Circle())
            #endif
    }
}

struct MusicLibraryActionSkeleton: View {
    var phoneLayout = PhonePageLayout()
    private var usesWideDetailHeader: Bool { !phoneLayout.isEnabled }
    var showsSaveButton = true

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.control) {
            if showsSaveButton { SkeletonView(cornerRadius: 28).frame(width: 56, height: 56) }
            SkeletonView(cornerRadius: 28).frame(minWidth: 116, maxWidth: .infinity).frame(height: 56)
            SkeletonView(cornerRadius: 28).frame(width: 56, height: 56)
        }
        .frame(maxWidth: 328)
        .padding(.horizontal, usesWideDetailHeader ? 0 : phoneLayout.contentInset)
    }
}
