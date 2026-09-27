on startsAt(oneEvent, startYear, startMonth, startDay, startHour, startMinute, startSecond)
    tell application "Calendar" to set eventDate to start date of oneEvent
    return ((year of eventDate) as integer) is startYear and ((month of eventDate) as integer) is startMonth and ((day of eventDate) as integer) is startDay and ((hours of eventDate) as integer) is startHour and ((minutes of eventDate) as integer) is startMinute and ((seconds of eventDate) as integer) is startSecond
end startsAt

on run argv
    if (count of argv) is not 10 then error "Expected mode, calendar name, title, local start components, and guest email"
    set operation to item 1 of argv
    set targetCalendarName to item 2 of argv
    set targetTitle to item 3 of argv
    set startYear to (item 4 of argv) as integer
    set startMonth to (item 5 of argv) as integer
    set startDay to (item 6 of argv) as integer
    set startHour to (item 7 of argv) as integer
    set startMinute to (item 8 of argv) as integer
    set startSecond to (item 9 of argv) as integer
    set guestEmail to item 10 of argv

    tell application "Calendar"
        set matchingEvents to {}
        repeat with oneCalendar in calendars
            if (name of oneCalendar) is targetCalendarName then
                set foundEvents to (events of oneCalendar whose summary is targetTitle)
                repeat with oneEvent in foundEvents
                    if my startsAt(contents of oneEvent, startYear, startMonth, startDay, startHour, startMinute, startSecond) then set end of matchingEvents to contents of oneEvent
                end repeat
            end if
        end repeat
        if (count of matchingEvents) is not 1 then error "Could not uniquely match the EventKit event in Calendar"
        if operation is "check" then return "matched"
        if operation is not "invite" then error "Unknown Calendar bridge operation"
        set selectedEvent to item 1 of matchingEvents

        repeat with oneAttendee in attendees of selectedEvent
            ignoring case
                if (email of oneAttendee) is guestEmail then return "already_present"
            end ignoring
        end repeat

        tell selectedEvent
            make new attendee at end of attendees with properties {email:guestEmail}
        end tell
        reload calendars

        repeat with oneAttendee in attendees of selectedEvent
            ignoring case
                if (email of oneAttendee) is guestEmail then return "added"
            end ignoring
        end repeat
        error "Calendar did not show the new attendee after the change"
    end tell
end run
