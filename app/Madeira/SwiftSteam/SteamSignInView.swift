// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

/// Steam sign-in sheet: account name + password with Steam Guard (a code and
/// in-app approval, offered together when Steam allows both), or a QR code
/// scanned with the Steam app (default on iPad). When signed in it shows the
/// account and Sign out.
struct SteamSignInView: View {
    @ObservedObject private var steam = SteamSignInModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var method: SteamSignInModel.SignInMethod = UIDevice.current.userInterfaceIdiom == .pad ? .qr : .password
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    private enum Field { case account, password, code }

    var body: some View {
        // Phase 2 (iOS 15.6): NavigationStack（16+）→ NavigationView；
        // .navigationViewStyle(.stack) 防止 iPad 上默认的双栏分栏布局。
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("登录 Steam", systemImage: "person.crop.circle.fill").font(.title2.bold())
                        Text("Madeira 会保留 Steam 登录状态，以便使用你的账户启动 Steam 游戏。")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if let name = steam.accountName {
                    signedInSection(name)
                } else if let prompt = steam.guardPrompt {
                    guardSection(prompt)
                } else {
                    Section {
                        Picker("登录方式", selection: $method) {
                            Text("密码").tag(SteamSignInModel.SignInMethod.password)
                            Text("二维码").tag(SteamSignInModel.SignInMethod.qr)
                        }.pickerStyle(.segmented)
                    }
                    if method == .password { passwordSection } else { qrSection }
                }
                if let error = steam.signInError {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Text("Madeira 会直接登录 Steam。你的密码只会发送给 Steam，不会被保存。登录令牌会保存在本设备的钥匙串中，直到你退出登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Steam").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(steam.signedIn ? "Done" : "Cancel") { steam.cancelSignIn(); dismiss() }
                }
            }
            .onAppear {
                steam.refresh(); steam.signInError = nil
                guard !steam.signedIn else { return }
                if method == .qr { steam.beginQR() } else { focus = .account }
            }
            .onChange(of: method) { value in
                steam.signInError = nil
                guard !steam.signedIn else { return }
                if value == .qr { steam.beginQR() } else { steam.cancelSignIn(); focus = .account }
            }
            .onChange(of: steam.accountName) { name in if name != nil { dismiss() } }
            .onChange(of: steam.guardPrompt) { prompt in if prompt?.codeType != nil { focus = .code } }
            .onDisappear { if !steam.signedIn { steam.cancelSignIn() } }
        }
        .navigationViewStyle(.stack)
    }

    private func signedInSection(_ name: String) -> some View {
        Section {
            // Phase 2 (iOS 15.6): LabeledContent（16+）→ 等价的左右布局行
            HStack {
                Text("账户")
                Spacer()
                Text(name).foregroundStyle(.secondary)
            }
            Button("退出登录", role: .destructive) { steam.signOut() }
        } footer: {
            Text("退出登录会从本设备的钥匙串中删除该令牌。")
        }
    }

    private var passwordSection: some View {
        Section {
            TextField("Steam 账户名称", text: $account)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .account).submitLabel(.next).onSubmit { focus = .password }
            SecureField("密码", text: $password)
                .textContentType(.password).focused($focus, equals: .password)
                .submitLabel(.go).onSubmit(submit)
            Button(action: submit) {
                HStack {
                    Text("登录").fontWeight(.semibold)
                    if steam.signInBusy { Spacer(); ProgressView() }
                }
            }.disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || steam.signInBusy)
        } footer: {
            Text("请使用 Steam 账户名称登录；它可能与电子邮箱地址不同。")
        }
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, !steam.signInBusy else { return }
        steam.signIn(account: account, password: password)
        password = ""
    }

    private func guardSection(_ prompt: SteamGuardPrompt) -> some View {
        Section {
            if let type = prompt.codeType {
                Text(type == .device
                     ? "Enter the Steam Guard code shown in the Steam app on your phone."
                     : "Enter the code Steam sent to your email" + (prompt.hint.isEmpty ? "." : " (\(prompt.hint))."))
                TextField("代码", text: $code)
                    .textContentType(.oneTimeCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.title3.monospaced()).focused($focus, equals: .code)
                    .submitLabel(.go).onSubmit { steam.submitGuardCode(code) }
                Button {
                    steam.submitGuardCode(code)
                } label: {
                    HStack { Text("继续").fontWeight(.semibold); if steam.signInBusy { Spacer(); ProgressView() } }
                }.disabled(code.trimmingCharacters(in: .whitespaces).count < 5 || steam.signInBusy)
            }
            if prompt.canApprove {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(prompt.codeType == nil
                         ? "Approve this sign-in in the Steam app on your phone."
                         : "Or approve this sign-in in the Steam app.")
                        .foregroundStyle(.secondary)
                }
            }
            Button("重新开始", role: .cancel) { code = ""; steam.cancelSignIn() }
        } header: { Text("Steam 令牌（Steam Guard）") }
    }

    private var qrSection: some View {
        Section {
            if let image = steam.qrImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 240).padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Steam 登录二维码")
                Text("在另一台设备上打开 Steam App，进入 Steam 令牌（Steam Guard），然后扫描此二维码。")
                if let link = steam.qrLink {
                    Button { UIApplication.shared.open(link) } label: {
                        Label("在此设备的 Steam App 中打开", systemImage: "arrow.up.forward.app")
                    }
                }
                HStack(spacing: 12) { ProgressView(); Text("等待批准…").foregroundStyle(.secondary) }
            } else if steam.signInBusy {
                HStack(spacing: 12) { ProgressView(); Text("正在获取登录验证码…").foregroundStyle(.secondary) }
            } else {
                Button("获取新代码") { steam.beginQR() }
            }
        }
    }
}
