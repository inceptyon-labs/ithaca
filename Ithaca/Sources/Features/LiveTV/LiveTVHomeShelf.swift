import SwiftUI

struct LiveTVHomeShelf: View {
    let viewModel: LiveTVViewModel
    let play: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void

    var body: some View {
        if let lineup = viewModel.nowPlayingLineup {
            let currentPrograms = lineup.guides.compactMap { guide -> (PlexLiveChannel, PlexLiveProgram)? in
                guard let program = guide.currentProgram() else { return nil }
                return (guide.channel, program)
            }

            if !currentPrograms.isEmpty {
                VStack(alignment: .leading, spacing: IthacaPosterMetrics.carouselSectionSpacing) {
                    Text("Live TV")
                        .font(IthacaFont.sectionHeader(ios: .title2.bold()))
                        .foregroundStyle(Color.ithacaTextPrimary)
                        .padding(.horizontal, IthacaPosterMetrics.carouselHorizontalPadding)

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(currentPrograms, id: \.1.id) { channel, program in
                                Button {
                                    play(channel, program, lineup)
                                } label: {
                                    LiveTVProgramCard(
                                        program: program,
                                        imageURL: viewModel.imageURL(
                                            for: program.preferredLandscapePath,
                                            width: 640,
                                            height: 360
                                        ),
                                        channelLogoURL: viewModel.imageURL(
                                            for: channel.thumb,
                                            width: 256,
                                            height: 256
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .ithacaTVOSFocusEffectShape(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                                .carouselLeadingFocusTarget()
                                .carouselItemFocusLock(isLeadingItem: program.id == currentPrograms.first?.1.id)
                            }
                        }
                        .padding(.horizontal, IthacaPosterMetrics.carouselHorizontalPadding)
                    }
                    .scrollIndicators(.hidden)
                    .carouselLeadingFocusLock(leadingInset: IthacaPosterMetrics.carouselHorizontalPadding)
                }
            }
        }
    }
}
