on run argv
    if (count of argv) is not 7 then error "Invalid Lima approval request."
    -- Quote every argument independently. No password passes through Lima,
    -- its command line, environment, logs, or preferences.
    set commandText to "/bin/zsh -f -c " & quoted form of (item 1 of argv) & " lima-approved-update"
    repeat with argumentIndex from 2 to 7
        set commandText to commandText & " " & quoted form of (item argumentIndex of argv)
    end repeat
    do shell script commandText with administrator privileges
end run
