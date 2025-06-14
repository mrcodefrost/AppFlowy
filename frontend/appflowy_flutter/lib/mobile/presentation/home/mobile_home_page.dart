import 'package:appflowy/features/workspace/data/repositories/rust_workspace_repository_impl.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/mobile/presentation/home/mobile_home_page_header.dart';
import 'package:appflowy/mobile/presentation/home/tab/mobile_space_tab.dart';
import 'package:appflowy/mobile/presentation/home/tab/space_order_bloc.dart';
import 'package:appflowy/shared/feature_flags.dart';
import 'package:appflowy/shared/loading.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:appflowy/user/application/auth/auth_service.dart';
import 'package:appflowy/user/application/reminder/reminder_bloc.dart';
import 'package:appflowy/workspace/application/command_palette/command_palette_bloc.dart';
import 'package:appflowy/workspace/application/favorite/favorite_bloc.dart';
import 'package:appflowy/workspace/application/menu/sidebar_sections_bloc.dart';
import 'package:appflowy/workspace/application/recent/cached_recent_service.dart';
import 'package:appflowy/workspace/application/sidebar/space/space_bloc.dart';
import 'package:appflowy/workspace/application/user/user_workspace_bloc.dart';
import 'package:appflowy/workspace/presentation/home/errors/workspace_failed_screen.dart';
import 'package:appflowy/workspace/presentation/home/home_sizes.dart';
import 'package:appflowy/workspace/presentation/home/menu/menu_shared_state.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:appflowy_backend/dispatch/dispatch.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/workspace.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-user/protobuf.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';

class MobileHomeScreen extends StatelessWidget {
  const MobileHomeScreen({super.key});

  static const routeName = '/home';

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: Future.wait([
        FolderEventGetCurrentWorkspaceSetting().send(),
        getIt<AuthService>().getUser(),
      ]),
      builder: (context, snapshots) {
        if (!snapshots.hasData) {
          return const Center(child: CircularProgressIndicator.adaptive());
        }

        final workspaceLatest = snapshots.data?[0].fold(
          (workspaceLatestPB) {
            return workspaceLatestPB as WorkspaceLatestPB?;
          },
          (error) => null,
        );
        final userProfile = snapshots.data?[1].fold(
          (userProfilePB) {
            return userProfilePB as UserProfilePB?;
          },
          (error) => null,
        );

        // In the unlikely case either of the above is null, eg.
        // when a workspace is already open this can happen.
        if (workspaceLatest == null || userProfile == null) {
          return const WorkspaceFailedScreen();
        }

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Provider.value(
              value: userProfile,
              child: MobileHomePage(
                userProfile: userProfile,
                workspaceLatest: workspaceLatest,
              ),
            ),
          ),
        );
      },
    );
  }
}

final PropertyValueNotifier<UserWorkspacePB?> mCurrentWorkspace =
    PropertyValueNotifier<UserWorkspacePB?>(null);

class MobileHomePage extends StatefulWidget {
  const MobileHomePage({
    super.key,
    required this.userProfile,
    required this.workspaceLatest,
  });

  final UserProfilePB userProfile;
  final WorkspaceLatestPB workspaceLatest;

  @override
  State<MobileHomePage> createState() => _MobileHomePageState();
}

class _MobileHomePageState extends State<MobileHomePage> {
  Loading? loadingIndicator;

  @override
  void initState() {
    super.initState();

    getIt<MenuSharedState>().addLatestViewListener(_onLatestViewChange);
    getIt<ReminderBloc>().add(const ReminderEvent.started());
  }

  @override
  void dispose() {
    getIt<MenuSharedState>().removeLatestViewListener(_onLatestViewChange);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (_) => UserWorkspaceBloc(
            userProfile: widget.userProfile,
            repository: RustWorkspaceRepositoryImpl(
              userId: widget.userProfile.id,
            ),
          )..add(UserWorkspaceEvent.initialize()),
        ),
        BlocProvider(
          create: (context) =>
              FavoriteBloc()..add(const FavoriteEvent.initial()),
        ),
        BlocProvider.value(
          value: getIt<ReminderBloc>()..add(const ReminderEvent.started()),
        ),
      ],
      child: _HomePage(userProfile: widget.userProfile),
    );
  }

  void _onLatestViewChange() async {
    final id = getIt<MenuSharedState>().latestOpenView?.id;
    if (id == null || id.isEmpty) {
      return;
    }
    await FolderEventSetLatestView(ViewIdPB(value: id)).send();
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage({required this.userProfile});

  final UserProfilePB userProfile;

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  Loading? loadingIndicator;

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<UserWorkspaceBloc, UserWorkspaceState>(
      buildWhen: (previous, current) =>
          previous.currentWorkspace?.workspaceId !=
          current.currentWorkspace?.workspaceId,
      listener: (context, state) {
        getIt<CachedRecentService>().reset();
        mCurrentWorkspace.value = state.currentWorkspace;
        if (FeatureFlag.search.isOn) {
          // Notify command palette that workspace has changed
          context.read<CommandPaletteBloc>().add(
                CommandPaletteEvent.workspaceChanged(
                  workspaceId: state.currentWorkspace?.workspaceId,
                ),
              );
        }
        Debounce.debounce(
          'workspace_action_result',
          const Duration(milliseconds: 150),
          () {
            _showResultDialog(context, state);
          },
        );
      },
      builder: (context, state) {
        if (state.currentWorkspace == null) {
          return const SizedBox.shrink();
        }

        final workspaceId = state.currentWorkspace!.workspaceId;

        return Column(
          key: ValueKey('mobile_home_page_$workspaceId'),
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.only(
                left: HomeSpaceViewSizes.mHorizontalPadding,
                right: 8.0,
              ),
              child: MobileHomePageHeader(
                userProfile: widget.userProfile,
              ),
            ),

            Expanded(
              child: MultiBlocProvider(
                providers: [
                  BlocProvider(
                    create: (_) =>
                        SpaceOrderBloc()..add(const SpaceOrderEvent.initial()),
                  ),
                  BlocProvider(
                    create: (_) => SidebarSectionsBloc()
                      ..add(
                        SidebarSectionsEvent.initial(
                          widget.userProfile,
                          workspaceId,
                        ),
                      ),
                  ),
                  BlocProvider(
                    create: (_) =>
                        FavoriteBloc()..add(const FavoriteEvent.initial()),
                  ),
                  BlocProvider(
                    create: (_) => SpaceBloc(
                      userProfile: widget.userProfile,
                      workspaceId: workspaceId,
                    )..add(
                        const SpaceEvent.initial(
                          openFirstPage: false,
                        ),
                      ),
                  ),
                ],
                child: MobileSpaceTab(
                  userProfile: widget.userProfile,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showResultDialog(BuildContext context, UserWorkspaceState state) {
    final actionResult = state.actionResult;
    if (actionResult == null) {
      return;
    }

    Log.info('workspace action result: $actionResult');

    final actionType = actionResult.actionType;
    final result = actionResult.result;
    final isLoading = actionResult.isLoading;

    if (isLoading) {
      loadingIndicator ??= Loading(context)..start();
      return;
    } else {
      loadingIndicator?.stop();
      loadingIndicator = null;
    }

    if (result == null) {
      return;
    }

    result.onFailure((f) {
      Log.error(
        '[Workspace] Failed to perform ${actionType.toString()} action: $f',
      );
    });

    final String? message;
    ToastificationType toastType = ToastificationType.success;
    switch (actionType) {
      case WorkspaceActionType.open:
        message = result.onFailure((e) {
          toastType = ToastificationType.error;
          return '${LocaleKeys.workspace_openFailed.tr()}: ${e.msg}';
        });
        break;
      case WorkspaceActionType.delete:
        message = result.fold(
          (s) {
            toastType = ToastificationType.success;
            return LocaleKeys.workspace_deleteSuccess.tr();
          },
          (e) {
            toastType = ToastificationType.error;
            return '${LocaleKeys.workspace_deleteFailed.tr()}: ${e.msg}';
          },
        );
        break;
      case WorkspaceActionType.leave:
        message = result.fold(
          (s) {
            toastType = ToastificationType.success;
            return LocaleKeys
                .settings_workspacePage_leaveWorkspacePrompt_success
                .tr();
          },
          (e) {
            toastType = ToastificationType.error;
            return '${LocaleKeys.settings_workspacePage_leaveWorkspacePrompt_fail.tr()}: ${e.msg}';
          },
        );
        break;
      case WorkspaceActionType.rename:
        message = result.fold(
          (s) {
            toastType = ToastificationType.success;
            return LocaleKeys.workspace_renameSuccess.tr();
          },
          (e) {
            toastType = ToastificationType.error;
            return '${LocaleKeys.workspace_renameFailed.tr()}: ${e.msg}';
          },
        );
        break;
      default:
        message = null;
        toastType = ToastificationType.error;
        break;
    }

    if (message != null) {
      showToastNotification(message: message, type: toastType);
    }
  }
}
