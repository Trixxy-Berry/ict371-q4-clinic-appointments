-- ============================================================================
-- ICT371 Advanced Database
-- Question 4: Clinic Appointment Scheduling (PostgreSQL / PL/pgSQL)
-- ============================================================================

-- (a) Database and seed data
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count  INT NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INT NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES
    ('Nomsa Dlamini'),
    ('Kelvin Mwanza'),
    ('Priscilla Sakala');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Joseph Chileshe'),
    ('Dr. Mary Mbewe'),
    ('Dr. Patrick Kasonde');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     TIME '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     TIME '10:00', 'ATTENDED'),
    (3, 1, CURRENT_DATE,     TIME '11:00', 'CANCELLED'),
    (1, 2, CURRENT_DATE + 1, TIME '09:00', 'BOOKED'),
    (2, 2, CURRENT_DATE + 1, TIME '12:00', 'BOOKED'),
    (3, 3, CURRENT_DATE + 2, TIME '10:00', 'BOOKED');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INT;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status IN ('BOOKED', 'ATTENDED');

    RETURN COALESCE(v_count, 0);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id  INT,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book an appointment in the past: %', p_day;
    END IF;

    IF p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot_time: %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IN ('BOOKED', 'ATTENDED') THEN
        IF EXISTS (
            SELECT 1
            FROM appointments
            WHERE doctor_id = NEW.doctor_id
              AND appointment_day = NEW.appointment_day
              AND slot_time = NEW.slot_time
              AND status IN ('BOOKED', 'ATTENDED')
              AND (TG_OP = 'INSERT' OR appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Slot clash for doctor % on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_check_appointment_clash();

-- (e) View
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- (f) Index, Query, and Plan
-- Justification: Non-unique composite index on (appointment_day, doctor_id) supports daily doctor schedule lookups while permitting multiple slots per day.
CREATE INDEX idx_appointments_day_doctor
ON appointments (appointment_day, doctor_id);

EXPLAIN
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT
        p_day,
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- Daily at 01:00 for the previous day (pg_cron)
SELECT cron.schedule(
    'refresh_clinic_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary((CURRENT_DATE - 1)::date);$$
);
