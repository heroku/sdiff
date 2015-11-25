-module(log_utils).
-compile(export_all).

level(Lvl) ->
    application:stop(lager),
    application:load(lager),
    application:set_env(lager, error_logger_hwm, 50000),
    application:set_env(lager, handlers, [
        {lager_console_backend, [
            Lvl,
            {lager_default_formatter, [
                " [",severity,"] (",
                pid, " ", module, ":", function, " ", line, ") ",
                message, "\n"
            ]}]}
    ]).
