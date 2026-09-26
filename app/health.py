# app/health.py
"""
Sleep data providers for SleepStake.
Includes the SleepRecord dataclass, abstract HealthProvider,
deterministic MockHealthProvider for demo/testing, and a GoogleHealthProvider stub.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from zoneinfo import ZoneInfo
from datetime import datetime

BERLIN_TZ = ZoneInfo("Europe/Berlin")

# Challenge sleep constraints (matches Solidity contract constants)
WINDOW_LENGTH_SEC = 9 * 3600  # 9 hours (e.g. 21:00 to 06:00)
MIN_SLEEP_SEC = 27000          # 7h 30m
MAX_SLEEP_SEC = 30600          # 8h 30m


@dataclass
class SleepRecord:
    """Represents sleep tracking data for a single night."""
    night: int
    sleep_start: int  # Unix timestamp in seconds
    sleep_end: int    # Unix timestamp in seconds

    @property
    def duration_sec(self) -> int:
        return self.sleep_end - self.sleep_start

    @property
    def duration_formatted(self) -> str:
        hours = self.duration_sec // 3600
        mins = (self.duration_sec % 3600) // 60
        return f"{hours}h {mins:02d}m"

    def evaluate_against_window(self, window_start: int) -> tuple[bool, str]:
        """
        Check if the sleep record meets the contract's rules:
        1. Window: starts >= window_start and ends <= window_start + 9 hours
        2. Duration: 7h30m (27,000s) <= duration <= 8h30m (30,600s)
        Returns (passed, reason_string).
        """
        window_end = window_start + WINDOW_LENGTH_SEC
        duration = self.duration_sec

        if self.sleep_start < window_start or self.sleep_end > window_end:
            return False, "OUTSIDE_WINDOW"
        if duration < MIN_SLEEP_SEC:
            return False, "TOO_SHORT"
        if duration > MAX_SLEEP_SEC:
            return False, "TOO_LONG"
        return True, "OK"


class HealthProvider(ABC):
    """Abstract base class for health & sleep data providers."""

    @abstractmethod
    def get_sleep(self, player_name: str, first_night_start: int, nights: int) -> list[SleepRecord]:
        """
        Fetch sleep records for a given player across challenge nights.
        :param player_name: Name or identifier of the player (e.g., 'Kai', 'Alice', 'Bob')
        :param first_night_start: Unix timestamp of 21:00 Berlin time on night 0
        :param nights: Total number of nights in the challenge
        :return: List of SleepRecord objects
        """
        pass


class MockHealthProvider(HealthProvider):
    """
    Deterministic mock provider generating realistic sleep records in Europe/Berlin time.
    - Kai: Passes all nights with solid 7h40m - 7h50m sleep within the window.
    - Alice: Passes all nights with 7h50m - 8h00m sleep within the window.
    - Bob: Passes night 0 (7h45m), but fails night 1 as TOO_SHORT (approx 6h40m = 24,000s).
    """

    def get_sleep(self, player_name: str, first_night_start: int, nights: int) -> list[SleepRecord]:
        name_lower = player_name.strip().lower()
        records: list[SleepRecord] = []

        for night in range(nights):
            # Each night window starts 24 hours after the previous night's 21:00
            window_start = first_night_start + night * 86400

            if "kai" in name_lower:
                if night == 0:
                    # 22:15 to 05:55 (7h 40m = 27,600s) -> PASS
                    start = window_start + (1 * 3600 + 15 * 60)
                    end = window_start + (8 * 3600 + 55 * 60)
                else:
                    # 22:00 to 05:50 (7h 50m = 28,200s) -> PASS
                    start = window_start + (1 * 3600)
                    end = window_start + (8 * 3600 + 50 * 60)

            elif "alice" in name_lower:
                if night == 0:
                    # 21:45 to 05:45 (8h 00m = 28,800s) -> PASS
                    start = window_start + (45 * 60)
                    end = window_start + (8 * 3600 + 45 * 60)
                else:
                    # 22:10 to 06:00 (7h 50m = 28,200s) -> PASS
                    start = window_start + (1 * 3600 + 10 * 60)
                    end = window_start + (9 * 3600)

            elif "bob" in name_lower:
                if night == 0:
                    # 22:00 to 05:45 (7h 45m = 27,900s) -> PASS
                    start = window_start + (1 * 3600)
                    end = window_start + (8 * 3600 + 45 * 60)
                else:
                    # Night 1: 23:00 to 05:40 (6h 40m = 24,000s < 27,000s) -> FAILS (TOO_SHORT)
                    start = window_start + (2 * 3600)
                    end = window_start + (8 * 3600 + 40 * 60)

            else:
                # Default fallback for any other name: passes with 8h sleep
                start = window_start + (1 * 3600)
                end = window_start + (9 * 3600)

            records.append(SleepRecord(night=night, sleep_start=start, sleep_end=end))

        return records


class GoogleHealthProvider(HealthProvider):
    """
    Production integration stub for Google Health Connect / Google Fit API.

    Future Architecture:
    1. OAuth 2.0 flow allows the user to grant read permission for SleepSession records.
    2. The backend or oracle service polls Google Health API for sleep intervals.
    3. The health data provider signs the payload using an ECDSA key (or generates a zk-proof
       via TLSNotary / zkWASM) to prove the data came untampered from Google's servers.
    4. Users or the oracle can submit the cryptographically signed sleep session directly to
       the smart contract without trusting a central administrator.
    """

    def get_sleep(self, player_name: str, first_night_start: int, nights: int) -> list[SleepRecord]:
        raise NotImplementedError(
            "GoogleHealthProvider is a roadmap feature. "
            "Production will integrate Google Health Connect with signed or zk-proven sleep sessions."
        )
