import SwiftUI

struct CoursePicker: View {
    let courseManager: CourseManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                Text("Grader")
                    .font(.largeTitle.bold())
                Text("PDF annotation and grading for courses")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 28)

            Divider()

            // Actions
            HStack(spacing: 16) {
                ActionButton(
                    title: "New Course",
                    subtitle: "Start a fresh gradebook",
                    icon: "plus.circle.fill",
                    color: .accentColor
                ) {
                    courseManager.newCourse()
                }

                ActionButton(
                    title: "Open Course",
                    subtitle: "Open a .gradercourse bundle",
                    icon: "folder.fill",
                    color: .orange
                ) {
                    courseManager.openExisting()
                }
            }
            .padding(24)

            // Recent courses
            if !courseManager.recentURLs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(courseManager.recentURLs.prefix(5), id: \.self) { url in
                        Button {
                            do { try courseManager.open(url: url) }
                            catch { NSAlert(error: error).runModal() }
                        } label: {
                            HStack {
                                Image(systemName: "doc.richtext")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.body)
                                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
