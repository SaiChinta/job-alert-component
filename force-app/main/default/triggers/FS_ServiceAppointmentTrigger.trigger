/**
 * @description Trigger on ServiceAppointment to populate work order lookups and create FS Alert Center records.
 */
trigger FS_ServiceAppointmentTrigger on ServiceAppointment (before insert, before update, after insert, after update) {
    FS_ServiceAppointmentTriggerHandler.handleTrigger(Trigger.new, Trigger.oldMap, Trigger.operationType);
}
