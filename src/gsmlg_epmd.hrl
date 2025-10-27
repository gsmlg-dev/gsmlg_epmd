%% Include guard
-ifndef(GSMLG_EPMD_HRL).
-define(GSMLG_EPMD_HRL, true).

%% Logging macros for OTP 21+ and older versions
-ifdef(OTP_RELEASE).
%% OTP 21+ with logger - use logger.hrl macros directly
-include_lib("kernel/include/logger.hrl").
-else.
%% Pre-OTP-21 with error_logger
-define(LOG_ERROR(Format, Args), error_logger:error_msg(Format, Args)).
-define(LOG_WARNING(Format, Args), error_logger:warning_msg(Format, Args)).
-define(LOG_INFO(Format, Args), error_logger:info_msg(Format, Args)).
-define(LOG_DEBUG(Format, Args), error_logger:info_msg(Format, Args)).
-endif.

-endif. %% GSMLG_EPMD_HRL
