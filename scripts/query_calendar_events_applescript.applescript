on replaceText(sourceText, searchText, replacementText)
    set AppleScript's text item delimiters to searchText
    set parts to text items of sourceText
    set AppleScript's text item delimiters to replacementText
    set resultText to parts as text
    set AppleScript's text item delimiters to ""
    return resultText
end replaceText

on pad2(value)
    set valueText to value as text
    if (count characters of valueText) is 1 then return "0" & valueText
    return valueText
end pad2

on iso8601(localDate)
    set yyyy to year of localDate as integer
    set mm to month of localDate as integer
    set dd to day of localDate as integer
    set hh to hours of localDate as integer
    set mins to minutes of localDate as integer
    set secs to seconds of localDate as integer
    return (yyyy as text) & "-" & my pad2(mm) & "-" & my pad2(dd) & "T" & my pad2(hh) & ":" & my pad2(mins) & ":" & my pad2(secs) & "+08:00"
end iso8601

on run argv
    if (count argv) is 0 then error "missing date argument"
    set dateText to item 1 of argv
    set yyyy to (text 1 thru 4 of dateText) as integer
    set mm to (text 6 thru 7 of dateText) as integer
    set dd to (text 9 thru 10 of dateText) as integer
    set monthValues to {January, February, March, April, May, June, July, August, September, October, November, December}
    set dayStart to current date
    set year of dayStart to yyyy
    set month of dayStart to item mm of monthValues
    set day of dayStart to dd
    set time of dayStart to 0
    set dayEnd to dayStart + (1 * days)
    set outputLines to {}

    tell application "Calendar"
        repeat with calendarRef in calendars
            set calendarName to name of calendarRef
            try
                set matchingEvents to (every event of calendarRef whose start date is greater than or equal to dayStart and start date is less than dayEnd)
                repeat with eventRef in matchingEvents
                    set eventSummary to my replaceText((summary of eventRef) as text, tab, " ")
                    set eventSummary to my replaceText(eventSummary, return, " ")
                    set eventSummary to my replaceText(eventSummary, linefeed, " ")
                    set eventNotes to ""
                    try
                        set eventNotes to (description of eventRef) as text
                    end try
                    set eventNotes to my replaceText(eventNotes, tab, " ")
                    set eventNotes to my replaceText(eventNotes, return, " ")
                    set eventNotes to my replaceText(eventNotes, linefeed, " ")
                    set eventStart to start date of eventRef
                    set eventEnd to end date of eventRef
                    set end of outputLines to (calendarName & tab & eventSummary & tab & (my iso8601(eventStart)) & tab & (my iso8601(eventEnd)) & tab & eventNotes)
                end repeat
            end try
        end repeat
    end tell
    set AppleScript's text item delimiters to linefeed
    return outputLines as text
end run
