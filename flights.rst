=========
 Flights
=========

---------
 Summary
---------

The flight booking/ticket creation workflow consists of four mandatory steps
for traditional flights. A fifth step (providing payment details) is required
when booking LCC flights.

 1. :ref:`FlightSearch`
 2. Details
 3. Booking
 4. Payment (mandatory only for LCC)
 5. Ticketing

.. _FlightSearch:

--------
 Search
--------

Request
=======

.. http:post:: /flights/

    Searches for flights that match provided criteria.

    :jsonparam String fromLocation: departure location, given as IATA code
    :jsonparam String toLocation: destination, given as IATA code
    :jsonparam String departureDate: date of departure, in ISO format
                                     *(including a time code, even though
                                     whole day will be searched by default)*
    :jsonparam String returnDate: date of return, in ISO format *(including
                                  a time code, even though whole day will be
                                  searched by default)*
    :jsonparam Person persons: a list of passengers, grouped by type code
                              containing Persons (see :ref:`Person`)
    :jsonparam String fromAirport: *(optional)* departure airport, given as
                                   IATA code, must be in the city specified in
                                   ``fromLocation``
    :jsonparam String toAirport: *(optional)* destination airport, given as
                                 IATA code, must be in the city specified in
                                 ``toLocation``
    :jsonparam String providerType: *(optional)* type of results to retrieve
    :jsonparam String[] airlines: *(optional)* list of airlines to filter
                                  results to, given as their two character IATA
                                  code

.. _Person:

Person
------

    :JSON Parameters:
        - **passengerType** (*String*) -- one of the available passenger types
          (see :ref:`PassengerTypes`)
        - **quantity** (*Integer*) -- number of travelers of ``passengerType``

Response
========

    :JSON Parameters:
        - **flightResultSet** (*FlightResult[]*) -- root container (see :ref:`FlightResult`)

.. _FlightResult:

FlightResult
------------

    :JSON Parameters:
        - **breakdown** (*Breakdown[]*) -- summary of passenger data per type
          (see :ref:`Breakdown`)
        - **currency** (*String*) -- currency of all prices in response
        - **total_fare** (*Float*) -- total fare, including service fee
        - **combinations** (*Combination[]*) -- list of combination objects
          (see :ref:`Combination`)

.. _Breakdown:

Breakdown
---------

    :JSON Parameters:
        - **fare** (*Float[]*) -- total price of the tickets for passengers of
          ``type``
        - **type** (*String*) -- type of passengers the breakdown is for, see
          (see :ref:`PassengerTypes`)
        - **quantity** (*Integer*) -- number of passengers of ``type``
        - **ticketDesignators** (*TicketDesignator[]*) -- ticket designators
          applicable for passengers of ``type`` (see :ref:`TicketDesignator`)

.. _TicketDesignator:

TicketDesignator
----------------

    Ticket designators are the mini-rules for the flight, with entries such as
    ``{"code": "70|PEN", "extension": "TICKETS ARE NON-REFUNDABLE|"}``.

    :JSON Parameters:
        - **code** (*String*) -- ticket designator's code
        - **extension** (*String*) -- ticket designator's description

.. _Combination:

Combination
-----------

    Combinations are the sets of different flight itineraries that can be
    booked. Every combination in a flight result is guaranteed to have the
    same total price, but the departure times, arrival times, and transfer
    locations can differ.

    .. note::
        As of May 2014, ``providerType`` can either be ``AmadeusProvider``, for
        traditional flights, or ``TravelFusionProvider``, for LCC flights.

    :JSON Parameters:
        - **providerType** (*String*) -- the provider the result is from
        - **bookingId** (*String*) -- the unique identifier of this
          combination (this is later used to identify the combination when
          booking, for example.)
        - **firstLeg** (*Leg*) -- The outbound leg of the itinerary
          (see :ref:`Leg`)
        - **returnLeg** (*Leg*) -- The inbound leg of the itinerary
          (see :ref:`Leg`)
        - **serviceFeeAmount** (*Float*) -- ticket designator's description

.. _Leg:

Leg
---

    Legs are made up of one or more segment, and span from one location the
    customer searched for to the other.

    :JSON Parameters:
        - **elapsedTime** (*String*) -- The total time between the leg's first
          departure, and last arrival (including time spent waiting when
          transferring). It is given in the format ``HHMM``.
        - **flightSegments** (*Segment[]*) -- The list of segments this leg is
          made up of. (see :ref:`Segment`)

.. _Segment:

Segment
-------

    Segments are the smallest unit of an itinerary. They are the direct
    flights the passenger will take from one airport to the other.

    :JSON Parameters:
        - **departure** (*Stop*) -- data about the flight's departure
          (see :ref:`Stop`)
        - **arrival** (*Stop*) -- data about the flight's arrival
          (see :ref:`Stop`)
        - **operatingAirline** (*String*) -- The airline operating this
          specific segment, given as a two character IATA code.
        - **availableBookingClasses** (*BookingClass[]*) -- a list of the
          classes that can be booked for this specific segment

            - **cabinCode** (*String*) --
            - **code** (*String*) --
            - **quantity** (*Integer*) --

.. _Stop:

Stop
----

    A stop is either the departure, or the arrival part of a segment.

    :JSON Parameters:
        - **dateTime** (*String*) -- time of the stop (in ISO format)
        - **airport** (*Airport*) -- location of the stop

           - **terminal** -- the relevant terminal of the airport specified
             below (this will be ``null`` is the airport has only one terminal)
           - **code** -- the three letter IATA code of the airport the stop is
             at

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "fromLocation": "BUD",
          "toLocation": "LON",
          "departureDate": "2014-05-15T00:00:00",
          "returnDate": "2014-05-20T00:00:00",
          "persons":[
            {
              "passengerType":"ADT",
              "quantity": 2
            },
            {
              "passengerType":"CHD",
              "quantity": 1
            }
          ]
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "flightResultSet": [
            {
              "breakdown": [
                {
                  "passengerFare": {
                    "fare": 52.8627,
                    "ticketDesignators": [],
                    "type": "ADT",
                    "quantity": 1
                  }
                }
              ],
              "currency": "EUR",
              "total_fare": 57.8627,
              "combinations": [
                {
                  "providerType": "TravelFusionProvider",
                  "bookingId": "15_0_0",
                  "firstLeg": {
                    "elapsedTime": "0230",
                    "flightSegments": [
                      {
                        "arrival": {
                          "airport": {
                            "terminal": null,
                            "code": "STN"
                          },
                          "dateTime": "2014-06-05T23:00:00"
                        },
                        "operatingAirline": "FR",
                        "departure": {
                          "airport": {
                            "terminal": null,
                            "code": "BUD"
                          },
                          "dateTime": "2014-06-05T21:30:00"
                        },
                        "availableBookingClasses": [
                          {
                            "cabinCode": "Y",
                            "code": "Y",
                            "quantity": 0
                          }
                        ]
                      }
                    ]
                  },
                  "serviceFeeAmount": 5.0
                }
              ]
            }
          ]
        }
