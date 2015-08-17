=============
 Car Rentals
=============

---------
 Summary
---------

The car rental workflow consists of three mandatory steps.

 1. :ref:`Car_Search`
 2. :ref:`Car_Payment`
 3. :ref:`Car_Booking`

Additional calls that are available:

 - :ref:`Car_Details`

.. _Car_Search:

--------
 Search
--------

Request
=======

.. http:post:: /cars

    Searches for cars that match provided criteria.

    :JSON Parameters:
        - **airport_code** (*String*) -- the IATA code of the airport to find
          available cars at
        - **start_date** (*String*) -- pickup date and time, in ISO
          format ex. 2014-12-24T12:00:00Z)
        - **end_date** (*String*) -- return date and time, in ISO
          format (ex. 2014-12-26T12:00:00Z)
        - **filters** (:ref:`Filter`) -- *(optional)* search filter
          for different car properties

.. _Filter:

Filter
------

    :JSON Parameters:
        - **type** (*String* *\[ \]*) -- one of the :ref:`car-types` listed
          below

Response Body
=============

    :JSON Parameters:
        - **car_results** (:ref:`car-result` *\[ \]*) -- root container

.. _car-result:

Car
---

    :JSON Parameters:
        - **vehicle_id** (*String*) -- The ID that identifies the car for
          getting its details or booking it
        - **vendor_id** (*String*) -- The ID to use for finding more results
          by this vendor
        - **vendor_name** (*String*)
        - **vendor_code** (*String*)
        - **available** (*Boolean*) -- Whether the car is available to book
        - **traits** (*Car Traits*) -- Certain properties of the car

           - **class** (*String*) -- One of the :ref:`car-classes` listed below
           - **type** (*String*) -- One of the :ref:`car-types` listed below
           - **transmission** (*String*) -- One of 'manual' or 'automatic'
           - **air_conditioning** (*Boolean*) -- Whether the car has AC or not

        - **price** (*Price*)

           - **amount** (*Float*)
           - **currency** (*String*)

        - **unlimited** (*Boolean*) -- Whether the booking fee covers unlimited
          usage for the car for the given number of days.
        - **overage_fee** (*Overage Fee*) -- These fields are relevant only if
          'unlimited' has a value of False above. Details the distance
          usage limitations and overage fees to be paid if the passenger goes
          over the given distance limit

           - **unit** (*String*) -- The distance unit that the value of the
             'included_distance' field's amount is given in, and also the
             unit of distance that the 'amount' field is valid for
           - **included_distance** (*Integer*) -- The distance that is
             included in the car's current price. Once this is reached, the
             passenger has to pay the per mile or per kilometer overage fee
             set below
           - **amount** (*Float*) -- The amount of money the passenger has to
             pay per unit of distance (mile or kilometer as given above) once
             they hit the given limit
           - **currency** (*String*)

To show some examples calculating the overage fee (developers using the API
will rarely need to really do this, but passengers need to be informed about
how this works, hence the detailed description here):

If 'overage_fee' has the values ``{"unit": "Mile", "included_distance": 1000, "amount": 0.05, "currency": "EUR"}`` and 'price' has the values ``{"amount": 150.0, "currency": "EUR"}``:

 - If the passenger drives 800 miles, they only have to pay the base price of
   150 EUR.
 - If the passenger drives 1400 miles, they pay the pay fee of 150 EUR plus
   400 miles times 0.05 EUR per mile, which comes out to 170 EUR in total.

Please note that the unit above could be kilometers as well.

.. _car-classes:

Available Car Classes
---------------------

  .. hlist::
      :columns: 3

      - mini
      - mini elite
      - economy
      - economy elite
      - compact
      - compact elite
      - intermediate
      - intermediate elite
      - standard
      - standard elite
      - full-size
      - full-size elite
      - premium
      - premium elite
      - luxury
      - luxury elite
      - oversize
      - special

.. _car-types:

Available Car Types
-------------------

  .. hlist::
      :columns: 3

      - 2 door car
      - 2/4 door car
      - 4 door car
      - coupe
      - SUV
      - crossover
      - motor home
      - open air all terrain
      - commercial van/truck
      - limousine
      - monospace
      - roadster
      - pick up regular cab
      - pick up extended cab
      - recreational vehicle
      - sport
      - convertible
      - passenger van
      - wagon/estate
      - special
      - 2 wheel vehicle
      - special offer car

Response Codes
==============

 - **410 'Location is closed at either the arrival or the departure time.'**

Examples
========

Request
-------

    **JSON (regular search):**

    .. sourcecode:: json

        {
          "airport_code": "LHR",
          "start_date": "2015-03-01T10:00:00Z",
          "end_date": "2015-03-04T10:00:00Z",
          "filters": {
            "type": [
              "crossover"
            ]
          }
        }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "car_results": [
            {
              "available": true,
              "traits": {
                "transmission": "manual",
                "air_conditioning": true,
                "type": "2/4 door car",
                "class": "mini"
              },
              "vehicle_id": "1_0_0",
              "vendor_name": "NATIONAL",
              "overage_fee": {
                "currency": "EUR",
                "amount": null,
                "unit": null,
                "included_distance": null
              },
              "price": {
                "currency": "EUR",
                "amount": "75.48"
              },
              "vendor_id": "0",
              "unlimited": true,
              "vendor_code": "ZL"
            },
            {
              "available": true,
              "traits": {
                "transmission": "manual",
                "air_conditioning": true,
                "type": "4-5 door car",
                "class": "compact"
              },
              "vehicle_id": "2_1_0",
              "vendor_name": "EUROPCAR",
              "overage_fee": {
                "currency": "EUR",
                "amount": "0.14",
                "unit": "Mile",
                "included_distance": 300
              },
              "price": {
                "currency": "EUR",
                "amount": "98.90"
              },
              "vendor_id": "1",
              "unlimited": false,
              "vendor_code": "EP"
            }
          ]
        }

.. _Car_Details:

---------
 Details
---------

Request
=======

.. http:get:: /cars/:vehicle_id

    **vehicle_id** is the ID of the :ref:`car-result` to get the details of

Response Body
=============

    :JSON Parameters:
        - **car_details** (:ref:`CarDetailsContainer`) -- root container

.. _CarDetailsContainer:

CarDetails
----------

    :JSON Parameters:
        - **locations** (:ref:`CarLocation` *\[ \]*) -- The list of the
          vendor's pick up/drop off locations.
        - **car_model** (*String*) -- The most exact name of the car that is
          available to us.
        - **included** (:ref:`Package` *\[ \]*) -- A list of things that are
          already included in the price, and are mandatory (this includes
          insurance fees, taxes, surcharges, etc.)
        - **extras** (:ref:`Package` *\[ \]*) -- A list of extras that the
          passenger is going to be able to buy when picking up the car.
        - **rules** (*String*) -- A string including longform text with the
          rules for renting given car.

.. _CarLocation:

Location
--------

    :JSON Parameters:
        - **city** (*String*)
        - **address** (*String*)
        - **phone** (*String*)
        - **fax** (*String*)
        - **opens_at** (*String*) -- In the format 'HH:MM'
        - **closes_at** (*String*) -- In the format 'HH:MM'

Package
-------

    :JSON Parameters:
        - **price** (*Price*)

          - **amount**
          - **currency**
        - **type** (*String*) -- The category that the package is in, one of
          'surcharge', 'tax', 'coverage', 'coupon' for included packages, or
          'child seat', 'child seat (<1 year)', 'child seat (1-3 years)',
          'child seat (4-7 years)', 'baby stroller', 'navigation system', or
          'extra coverage' for extras.
        - **period** (*String*) -- The period that the given price applies to,
          one of: 'day', 'week', 'month', or 'rental' - renting a car for 5
          days means that adding an extra with a day period set here for the
          entire trip is going to add five times the 'price' amount to the
          total price.
        - **description** (*String*) -- The exact name of the package, such as
          type of insurance.

Examples
========

Response
--------

    **JSON:**

    .. sourcecode:: json

      {
        "car_details": {
          "included": [
            {
              "price": {
                "currency": "EUR",
                "amount": "0.00"
              },
              "type": "surcharge",
              "period": "day",
              "description": "DAMAGE LIABILITY WAIVER"
            },
            {
              "price": {
                "currency": "EUR",
                "amount": "11.99"
              },
              "type": "coverage",
              "period": "day",
              "description": "CDW - COLLISION DAMAGE WAIVER"
            },
            {
              "price": {
                "currency": "GBP",
                "amount": "20.00"
              },
              "type": "tax",
              "period": "rental",
              "description": "VALUE ADDED TAX"
            }
          ],
          "car_model": "FIAT 500 OR SIMILAR",
          "extras": [
            {
              "price": {
                "currency": "EUR",
                "amount": "13.98"
              },
              "type": "extra coverage",
              "period": "day",
              "description": "MCP"
            }
          ],
          "rules": "BASE RATE INCLUDES SURCHARGES\nBASE RATE INCLUDES TAXES\nPRICE INCLUDES TAX SURCHARGE INSURANCE. 0.00 GBP\nDAMAGE LIABILITY WAIVER ALREADY INCLUDED.\nIATA NBR NOT ON FILE QUEUE AGENCY INFO TO ZL\nALLOWED - RETURN TO SPECIFIED LOCATION ONLY\nA MINIMUM OF 3 DAYS WILL BE CHARGED",
          "locations": [
            {
              "closes_at": "23:59",
              "city": "GB",
              "fax": null,
              "phone": "44 08713843410",
              "address": "EUROPCAR AND NATIONAL HEATHROW NORTHER",
              "opens_at": "00:00"
            }
          ]
        }
      }

.. _Car_Payment:

---------
 Payment
---------

Request
=======

.. http:post:: /payment

    :JSON Parameters:
        - **payuId** (*String*) -- the transaction ID identifying the
          successful transaction at PayU
        - **basket** (*String \[ \]*) -- contains the booking IDs the payment
          was made for (this array will normally have only one item in it)

Response Body
=============

    **N/A:**

    Returns an HTTP 204 No Content status code if successful.

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

        {
          "payuId": "12345678",
          "basket": ["1_0_0"]
        }

.. _Car_Booking:

---------
 Booking
---------

Request
=======

.. http:post:: /books

    :JSON Parameters:
        - **bookBasket** (*String \[ \]*) -- an array containing only the
          booking ID of the :ref:`Room` to book
        - **billingInfo** (:ref:`Contact`) -- billing info for the booking
        - **contactInfo** (:ref:`Contact`) -- contact info for the booking
        - **persons** (:ref:`Person` *\[ \]*) -- the list of occupants

.. _CarContact:

Contact
-------

    :JSON Parameters:
        - **address** (:ref:`CarAddress`) -- address of the entity in question
        - **email** (*String*) -- email of the entity in question
        - **name** (*String*) -- name of the entity in question
        - **phone** (:ref:`CarPhone`) -- phone number of the entity in
          question

.. _CarAddress:

Address
-------

    :JSON Parameters:
        - **addressLine1** (*String*)
        - **addressLine2** (*String*) -- *(optional)*
        - **addressLine3** (*String*) -- *(optional)*
        - **cityName** (*String*)
        - **zipCode** (*String*)
        - **countryCode** (*String*) -- the two letter code of the country

.. _CarPhone:

Phone
-----

    :JSON Parameters:
        - **countryCode** (*Integer*)
        - **areaCode** (*Integer*)
        - **phoneNumber** (*Integer*)

.. _CarPerson:

Person
------

    :JSON Parameters:
        - **birthDate** (*String*) -- format is ``YYYY-MM-DD``
        - **email** (*String*)
        - **namePrefix** (*String*) -- one of ``Mr``, ``Ms``, or ``Mrs``
        - **firstName** (*String*)
        - **lastName** (*String*)
        - **gender** (*String*) -- one of ``MALE`` or ``FEMALE``
        - **document** (:ref:`CarDocument`) -- data about the identifying
          document the person wishes to travel with

.. _CarDocument:

Document
--------

    :JSON Parameters:
        - **id** (*String*) -- document's ID number
        - **dateOfExpiry** (*String*) -- format is YYYY-MM-DD
        - **issueCountry** (*String*) -- two letter code of issuing country
        - **type** (*String*) -- one of :ref:`DocumentTypes`

Response Body
=============

    :JSON Parameters:
        - **confirmation** (*String*) -- the ID of the booking, this is what
          the occupant can use at the car vendor to refer to his booking
        - **pnr** (*String*) -- the PNR locator of the record in which the
          booking was made

Examples
========

Request
-------

    **JSON:**

    .. sourcecode:: json

      {
        "billingInfo": {
          "address": {
            "addressLine1": "Váci út 13-14",
            "cityName": "Budapest",
            "countryCode": "HU",
            "zipCode": "1234"
          },
          "email": "ccc@gmail.com",
          "name": "Kovacs Gyula",
          "phone": {
            "areaCode": "30",
            "countryCode": "36",
            "phoneNumber": "1234567"
          }
        },
        "bookBasket": [
          "33_0_0"
        ],
        "contactInfo": {
          "address": {
            "addressLine1": "Váci út 13-14",
            "cityName": "Budapest",
            "countryCode": "HU",
            "zipCode": "1234"
          },
          "email": "ccc@gmail.com",
          "name": "Kovacs Gyula",
          "phone": {
            "areaCode": "30",
            "countryCode": "36",
            "phoneNumber": "1234567"
          }
        },
        "persons": [
          {
            "birthDate": "1974-04-03",
            "document": {
              "dateOfExpiry": "2016-09-03",
              "id": "12345678",
              "issueCountry": "HU",
              "type": "Passport"
            },
            "email": "aaa@gmail.com",
            "firstName": "Janos",
            "gender": "MALE",
            "lastName": "Kovacs",
            "namePrefix": "Mr"
          }
        ]
      }

Response
--------

    **JSON:**

    .. sourcecode:: json

        {
          "confirmation": "1647353336COUNT",
          "pnr": "6KSSY3"
        }
